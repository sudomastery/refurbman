/**
 * The shape the probe engine hands over.
 *
 * These mirror `crates/probe/src/report.rs`. They are written out by hand
 * rather than generated because the surface is small and stable, and a
 * hand-written type can carry the explanation of what a field means.
 */

/** How resistant to tampering the origin of a value is. Higher is harder to fake. */
export const Trust = {
  /** Mutable userspace configuration. Never backs a hardware claim. */
  Software: 0,
  /** Worked out by RefurbMan from the readings below it. */
  Derived: 1,
  /** Firmware tables the kernel passes through. Faking means reflashing the BIOS. */
  Firmware: 2,
  /** The kernel's own live view. Faking means patching a running kernel. */
  Kernel: 3,
  /** The part itself answered. Faking means reflashing the part. */
  Device: 4,
} as const;

export type TrustRank = (typeof Trust)[keyof typeof Trust];

export interface Fact {
  value: string | number | boolean;
  /** The literal path or call this came from, so a sceptic can go and check. */
  source: string;
  trust: TrustRank;
  trustLabel: string;
  unit?: string;
}

export type Facts = Record<string, Fact>;

export type Verdict = "good" | "fair" | "poor" | "unknown";
export type Severity = "info" | "warn" | "critical";
export type CheckStatus = "pass" | "suspicious" | "fail" | "skipped";

export interface Finding {
  severity: Severity;
  title: string;
  detail: string;
  evidence?: string | null;
}

export interface Component {
  kind: string;
  name: string;
  facts: Facts;
}

export interface Consumable {
  kind: "storage" | "battery" | string;
  name: string;
  /** Remaining life, 100 being factory-new. Null when the part would not say. */
  percent: number | null;
  verdict: Verdict;
  headline: string;
  facts: Facts;
  findings: Finding[];
}

export interface TamperCheck {
  id: string;
  title: string;
  status: CheckStatus;
  detail: string;
}

export interface TrustSummary {
  totalFacts: number;
  tamperResistantFacts: number;
  tamperResistantPercent: number;
  fullAccess: boolean;
}

export interface Report {
  generatedAt: string;
  toolVersion: string;
  platform: string;
  privileged: boolean;
  system: Facts;
  components: Component[];
  consumables: Consumable[];
  findings: Finding[];
  tamperChecks: TamperCheck[];
  trust: TrustSummary;
  /** Probes that failed. Kept visible so a short section is never mistaken
      for a machine with little in it. */
  errors: string[];
}

export interface Readiness {
  privileged: boolean;
  platform: string;
  canElevate: boolean;
  toolVersion: string;
}

/**
 * Which readings each section shows, and in what order.
 *
 * Facts arrive alphabetically so exports stay byte-stable, which is the wrong
 * order to read in. This mirrors `display_fields` in the engine so the window
 * and the exported report never disagree about what matters.
 */
export const DISPLAY_FIELDS: Record<string, [string, string][]> = {
  cpu: [
    ["model", "Processor"],
    ["vendor", "Made by"],
    ["cores", "Cores"],
    ["threads", "Threads"],
    ["maxFrequencyMhz", "Maximum speed"],
    ["hypervisor", "Virtualised under"],
  ],
  memory: [
    ["size", "Size"],
    ["type", "Type"],
    ["configuredSpeedMts", "Running at"],
    ["manufacturer", "Made by"],
    ["partNumber", "Part number"],
  ],
  storage: [
    ["capacity", "Capacity"],
    ["kind", "Type"],
    ["protocol", "Connection"],
    ["powerOnFor", "Powered on for"],
    ["totalWritten", "Total written"],
    ["lifeUsedPercent", "Life used"],
    ["temperatureC", "Temperature"],
    ["selfAssessment", "Drive self-check"],
    ["reallocatedSectors", "Replaced areas"],
    ["pendingSectors", "Areas it cannot read"],
    ["uncorrectableSectors", "Unrecoverable areas"],
    ["mediaErrors", "Unrecoverable errors"],
    ["powerCycles", "Times switched on"],
    ["firmware", "Firmware"],
  ],
  battery: [
    ["designCapacityWh", "Capacity when new"],
    ["currentCapacityWh", "Capacity now"],
    ["cycleCount", "Charge cycles"],
    ["technology", "Chemistry"],
    ["manufacturer", "Made by"],
    ["chargeNowPercent", "Charged right now"],
    ["status", "Currently"],
  ],
};

export const MACHINE_FIELDS: [string, string][] = [
  ["manufacturer", "Manufacturer"],
  ["model", "Model"],
  ["family", "Family"],
  ["sku", "SKU"],
  ["serialNumber", "Serial number"],
  ["chassis", "Form"],
  ["boardVendor", "Motherboard maker"],
  ["boardModel", "Motherboard"],
  ["biosVendor", "BIOS maker"],
  ["biosVersion", "BIOS version"],
  ["biosDate", "BIOS date"],
];

/** Render a fact's value with its unit, leaving raw byte counts alone. */
export function factText(f: Fact): string {
  const base = typeof f.value === "boolean" ? (f.value ? "yes" : "no") : String(f.value);
  return f.unit && f.unit !== "bytes" ? `${base} ${f.unit}` : base;
}

/**
 * The machine's name for the header.
 *
 * Manufacturers repeat themselves: "HP" alongside "HP Pavilion Aero" should
 * read as one name, not two.
 */
export function machineName(report: Report): string {
  const vendor = report.system["manufacturer"]?.value;
  const model = report.system["model"]?.value;
  const v = vendor === undefined ? "" : String(vendor);
  const m = model === undefined ? "" : String(model);
  if (v && m && m.startsWith(`${v} `)) return m;
  const joined = [v, m].filter(Boolean).join(" ");
  return joined || "Unidentified machine";
}
