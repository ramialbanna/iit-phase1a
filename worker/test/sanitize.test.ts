import { test } from "node:test";
import assert from "node:assert/strict";
import { assertAllowlisted, sanitizeAppraisal, VAUTO_BODY_ALLOWLIST } from "../src/sanitize.ts";

const full = {
  id: "A-1", isCompleted: true, created: "2026-10-20T10:00:00Z", lastModified: "2026-10-21T09:00:00Z", centralizedStatus: "Completed",
  organization: { entityLogicalId: "ent-1" },
  vehicle: { vin: "WAUZZZ8V7JA000100", year: 2019, make: "Audi", model: "A4", series: "Premium", seriesDetail: "Plus", bodyType: "Sedan", odometer: 41200, exteriorColor: "Gray", location: "Lot B" },
  remarks: { vehicleConditionNotes: "Customer name: Ann; owes 12000 to Big Bank" },
  personnel: { appraiser: { userName: "appr.1", firstName: "A", emailAddress: "a@x" }, salesPerson: { userName: "rami.b" } },
  customer: { firstName: "Ann", lastName: "Seller", homePhone: "555-1", workPhone: "555-2", mobilePhone: "555-3", pagerPhone: "555-4", emailAddress: "ann@x", address: "1 Main St", postalCode: "75001" },
  appraisalValue: { appraisedValue: 14500 },
  financial: { exitStrategyType: "Retail", reconditioningCost: 900, lien: { owner: "Big Bank", accountNumber: "123456789", phoneNumber: "555-9", address: "2 Bank St", payoff: 12000.5, payoffDate: "2026-11-01T00:00:00Z", payoffPerDiem: 4.1 } },
  titleRegistration: { title: { name: "Ann Seller", region: "FL" }, tag: { tag: "ABC123", region: "TX", expiration: "2027-01-01T00:00:00Z" } },
  condition: { salvaged: false, floodDamage: false },
};

test("full response → exactly the allowlisted body; prohibited and unmapped fields are absent", () => {
  const r = sanitizeAppraisal(full);
  assert.equal(r.ok, true); if (!r.ok) return;
  assert.equal(r.value.id, "A-1"); assert.equal(r.value.completed, true);
  assert.deepEqual(r.value.body, {
    vehicle: { vin: "WAUZZZ8V7JA000100", year: 2019, make: "Audi", model: "A4", series: "Premium", trim: "Plus", exterior_color: "Gray", mileage: 41200 },
    appraisal: { value: 14500, status: "Completed", is_completed: true },
    personnel: { appraiser: "appr.1", buyer: "rami.b" },
    customer: { first_name: "Ann", last_name: "Seller", phone: "555-3", email: "ann@x", postal_code: "75001" },
    title: { region: "FL", name: "Ann Seller" }, tag: { value: "ABC123" },
    lien: { owner: "Big Bank", phone: "555-9", payoff: 12000.5, payoff_date: "2026-11-01T00:00:00Z", per_diem: 4.1 },
    timestamps: { created: "2026-10-20T10:00:00Z", last_modified: "2026-10-21T09:00:00Z" },
  });
  const s = JSON.stringify(r.value.body);
  for (const forbidden of ["123456789", "1 Main St", "2 Bank St", "vehicleConditionNotes", "owes 12000", "Lot B", "Retail", "a@x", "closer"]) assert.ok(!s.includes(forbidden), forbidden);
  assert.equal(assertAllowlisted(r.value.body), null);
});
test("phone precedence mobile → home → work; empty strings are absent, not empty", () => {
  const r = sanitizeAppraisal({ id: "A", customer: { homePhone: "h", workPhone: "w" } }); assert.ok(r.ok && (r.value.body.customer as { phone: string }).phone === "h");
  const r2 = sanitizeAppraisal({ id: "A", customer: { workPhone: "w", mobilePhone: " " } }); assert.ok(r2.ok && (r2.value.body.customer as { phone: string }).phone === "w");
  const r3 = sanitizeAppraisal({ id: "A", customer: { firstName: "" }, vehicle: { vin: "" } }); assert.ok(r3.ok && !("customer" in r3.value.body) && !("vehicle" in r3.value.body));
});
test("no id / not an object → refused; wrong types are dropped rather than coerced", () => {
  assert.deepEqual(sanitizeAppraisal({ vehicle: {} }), { ok: false, reason: "no_id" });
  assert.deepEqual(sanitizeAppraisal("x"), { ok: false, reason: "not_object" });
  const r = sanitizeAppraisal({ id: "A", vehicle: { year: "2019", odometer: "41200" }, appraisalValue: { appraisedValue: "14500" }, isCompleted: "true" });
  assert.ok(r.ok && !("vehicle" in r.value.body) && !("appraisal" in r.value.body) && r.value.completed === undefined);
});
test("assertAllowlisted mirrors the database rule: unknown keys, structures under leaves and bad array elements are caught", () => {
  assert.equal(assertAllowlisted({ lien: { accountNumber: "1" } }), "lien.accountNumber");
  assert.equal(assertAllowlisted({ vehicle: { vin: { nested: 1 } } }), "vehicle.vin");
  assert.equal(assertAllowlisted({ notes_sanitized: { labels: [{ label: "a", value: "b" }] } }), null);
  assert.equal(assertAllowlisted({ notes_sanitized: { labels: [{ label: "a", raw: "b" }] } }), "notes_sanitized.labels[].raw");
  assert.equal(assertAllowlisted({ customer: { address: "x" } }), "customer.address");
  // the constant mirrors 001's json_schemas.vauto_observation key for key
  assert.deepEqual(Object.keys(VAUTO_BODY_ALLOWLIST).sort(), ["appraisal", "condition", "customer", "lien", "notes_sanitized", "personnel", "tag", "timestamps", "title", "vehicle"]);
});
