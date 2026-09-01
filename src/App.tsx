import { useCallback, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { save } from "@tauri-apps/plugin-dialog";

import {
  Badge,
  Card,
  CheckRow,
  FindingRow,
  Meter,
  Row,
  Section,
  verdictInk,
} from "./components/primitives";
import {
  DISPLAY_FIELDS,
  MACHINE_FIELDS,
  machineName,
  type Consumable,
  type Readiness,
  type Report,
} from "./lib/types";

type View = "overview" | "hardware" | "checks" | "findings";

const VIEWS: [View, string][] = [
  ["overview", "Overview"],
  ["hardware", "Hardware"],
  ["checks", "Checks"],
  ["findings", "What to know"],
];

export default function App() {
  const [ready, setReady] = useState<Readiness | null>(null);
  const [report, setReport] = useState<Report | null>(null);
  const [scanning, setScanning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [view, setView] = useState<View>("overview");
  const [saved, setSaved] = useState<string | null>(null);

  useEffect(() => {
    invoke<Readiness>("readiness").then(setReady).catch(() => setReady(null));
  }, []);

  const scan = useCallback(async () => {
    setScanning(true);
    setError(null);
    setSaved(null);
    try {
      const r = await invoke<Report>("run_scan");
      setReport(r);
      setView("overview");
    } catch (e) {
      setError(String(e));
    } finally {
      setScanning(false);
    }
  }, []);

  const elevate = useCallback(async () => {
    try {
      await invoke("relaunch_elevated");
    } catch (e) {
      setError(String(e));
    }
  }, []);

  const exportReport = useCallback(async () => {
    if (!report) return;
    try {
      const name = machineName(report).replace(/[^\w.-]+/g, "-").toLowerCase();
      const path = await save({
        title: "Save the report",
        defaultPath: `refurbman-${name}.html`,
        filters: [{ name: "Report", extensions: ["html"] }],
      });
      if (!path) return;
      // The engine renders from the scan it still holds, so the saved document
      // cannot differ from what the user is looking at, and no large report has
      // to travel back across the bridge.
      const html = await invoke<string>("render_html");
      const written = await invoke<string>("save_html", { path, html });
      setSaved(written);
    } catch (e) {
      setError(String(e));
    }
  }, [report]);

  if (!report) {
    return (
      <StartScreen
        ready={ready}
        scanning={scanning}
        error={error}
        onScan={scan}
        onElevate={elevate}
      />
    );
  }

  return (
    <div className="flex h-full flex-col">
      <Header
        report={report}
        scanning={scanning}
        onRescan={scan}
        onExport={exportReport}
        saved={saved}
      />

      <div className="flex-none border-b hairline">
        <nav className="mx-auto flex max-w-4xl gap-1 px-6" aria-label="Sections">
          {VIEWS.map(([id, label]) => (
          <button
            key={id}
            onClick={() => setView(id)}
            aria-current={view === id ? "page" : undefined}
            className="-mb-px border-b-2 px-3 py-2 text-sm font-medium transition-colors"
            style={{
              borderColor: view === id ? "var(--ink)" : "transparent",
              color: view === id ? "var(--ink)" : "var(--ink-3)",
            }}
          >
            {label}
            {id === "findings" && report.findings.length > 0 && (
              <span className="ml-1.5 text-xs ink-3">{report.findings.length}</span>
            )}
          </button>
          ))}
        </nav>
      </div>

      <main className="min-h-0 flex-1 overflow-y-auto px-6 py-6">
        <div className="mx-auto max-w-4xl">
          {error && <Banner tone="critical" text={error} />}
          {!report.privileged && <UnlockNotice ready={ready} onElevate={elevate} />}

          {view === "overview" && <Overview report={report} />}
          {view === "hardware" && <Hardware report={report} />}
          {view === "checks" && <Checks report={report} />}
          {view === "findings" && <Findings report={report} />}
        </div>
      </main>
    </div>
  );
}

/* ------------------------------------------------------------------ start */

function StartScreen({
  ready,
  scanning,
  error,
  onScan,
  onElevate,
}: {
  ready: Readiness | null;
  scanning: boolean;
  error: string | null;
  onScan: () => void;
  onElevate: () => void;
}) {
  return (
    <div className="flex h-full items-center justify-center px-6">
      <div className="w-full max-w-lg text-center">
        <p className="text-[11px] font-bold uppercase tracking-[0.16em] ink-3">RefurbMan</p>
        <h1 className="mt-2 text-3xl font-semibold">What is really in this machine?</h1>
        <p className="mx-auto mt-3 max-w-md ink-2">
          RefurbMan reads the hardware and how worn it is from the operating system, the
          motherboard firmware and the parts themselves, rather than from anything a seller
          can easily edit.
        </p>

        <button
          onClick={onScan}
          disabled={scanning}
          className="mt-8 w-full rounded-xl px-6 py-4 text-lg font-semibold text-white transition-opacity disabled:opacity-70"
          style={{ background: "var(--accent)" }}
        >
          {scanning ? "Checking this machine…" : "Check this machine"}
        </button>

        {scanning && (
          <div className="scanning surface-3 relative mt-4 h-1 overflow-hidden rounded-full" />
        )}

        {ready && !ready.privileged && !scanning && (
          <p className="mt-4 text-sm ink-3">
            This will check everything except how worn the drives are.{" "}
            {ready.canElevate ? (
              <button onClick={onElevate} className="underline" style={{ color: "var(--accent)" }}>
                {ready.platform === "windows"
                  ? "Restart as administrator"
                  : "Unlock the full check"}
              </button>
            ) : (
              <span>
                {ready.platform === "windows"
                  ? "Right click RefurbMan and choose Run as administrator for the full check."
                  : "Start RefurbMan with sudo for the full check."}
              </span>
            )}
          </p>
        )}

        {error && (
          <div className="mt-6 text-left">
            <Banner tone="critical" text={error} />
          </div>
        )}
      </div>
    </div>
  );
}

/* ----------------------------------------------------------------- header */

function Header({
  report,
  scanning,
  onRescan,
  onExport,
  saved,
}: {
  report: Report;
  scanning: boolean;
  onRescan: () => void;
  onExport: () => void;
  saved: string | null;
}) {
  const sub = [report.system["chassis"]?.value, report.system["serialNumber"]?.value]
    .filter(Boolean)
    .map(String);

  return (
    <header className="flex-none border-b px-6 pb-4 pt-5 hairline">
      <div className="mx-auto flex max-w-4xl flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <p className="text-[11px] font-bold uppercase tracking-[0.16em] ink-3">RefurbMan</p>
          <h1 className="selectable mt-1 truncate text-2xl font-semibold">
            {machineName(report)}
          </h1>
          {sub.length > 0 && (
            <p className="selectable mt-0.5 text-sm ink-2">{sub.join(" · ")}</p>
          )}
        </div>
        <div className="flex flex-none gap-2">
          <button
            onClick={onExport}
            className="rounded-lg border px-3 py-2 text-sm font-medium hairline"
          >
            Save report
          </button>
          <button
            onClick={onRescan}
            disabled={scanning}
            className="rounded-lg px-3 py-2 text-sm font-medium text-white disabled:opacity-70"
            style={{ background: "var(--accent)" }}
          >
            {scanning ? "Checking…" : "Check again"}
          </button>
        </div>
      </div>
      {saved && (
        <p className="mx-auto mt-2 max-w-4xl text-sm ink-2">
          Saved to <span className="selectable font-mono text-xs">{saved}</span>. Open it and
          choose Print, then Save as PDF, for a PDF copy.
        </p>
      )}
    </header>
  );
}

/* --------------------------------------------------------------- overview */

function Overview({ report }: { report: Report }) {
  const worst = useMemo(() => {
    const order = { poor: 3, unknown: 2, fair: 1, good: 0 } as const;
    return report.consumables.reduce<Consumable | null>(
      (acc, c) => (acc === null || order[c.verdict] > order[acc.verdict] ? c : acc),
      null,
    );
  }, [report.consumables]);

  return (
    <>
      {worst && (
        <p className="mb-6 text-lg" style={{ color: verdictInk(worst.verdict) }}>
          {worst.verdict === "good"
            ? "Nothing here looks worn out."
            : worst.verdict === "unknown"
              ? "Some readings on this machine do not add up. Read on."
              : `The ${worst.kind === "battery" ? "battery" : "drive"} is the weak point here.`}
        </p>
      )}

      <Section title="Condition of the parts that wear out">
        {report.consumables.length === 0 ? (
          <p className="ink-3">No drives or batteries were found.</p>
        ) : (
          <div className="grid gap-4 sm:grid-cols-2">
            {report.consumables.map((c, i) => (
              <ConsumableCard key={`${c.kind}-${c.name}-${i}`} c={c} />
            ))}
          </div>
        )}
      </Section>

      <Section title="This machine">
        <FactList facts={report.system} fields={MACHINE_FIELDS} />
      </Section>

      <TrustSummary report={report} />
    </>
  );
}

function ConsumableCard({ c }: { c: Consumable }) {
  const fields = DISPLAY_FIELDS[c.kind] ?? [];
  return (
    <Card>
      <div className="flex items-baseline justify-between gap-3">
        <h3 className="selectable min-w-0 break-words font-semibold">{c.name}</h3>
        <Badge verdict={c.verdict} />
      </div>
      <Meter
        label={c.kind === "battery" ? "Capacity remaining" : "Life remaining"}
        percent={c.percent}
        verdict={c.verdict}
      />
      {c.headline && <p className="mt-3 text-sm ink-2">{c.headline}</p>}
      <div className="mt-3">
        <FactList facts={c.facts} fields={fields} />
      </div>
    </Card>
  );
}

function FactList({
  facts,
  fields,
}: {
  facts: Report["system"];
  fields: [string, string][];
}) {
  const rows = fields.filter(([key]) => facts[key] !== undefined);
  if (rows.length === 0) return <p className="text-sm ink-3">Nothing was reported here.</p>;
  return (
    <div>
      {rows.map(([key, label]) => (
        <Row key={key} label={label} fact={facts[key]!} />
      ))}
    </div>
  );
}

function TrustSummary({ report }: { report: Report }) {
  const t = report.trust;
  return (
    <Section title="Where these readings came from">
      <p className="mb-3 max-w-3xl ink-2">
        {t.tamperResistantFacts} of {t.totalFacts} readings come from the firmware or from the
        parts themselves, rather than from software anyone can edit.
      </p>
      <div className="flex items-center gap-3">
        <div
          className="h-[9px] flex-1 overflow-hidden rounded-full"
          style={{ background: "color-mix(in oklab, var(--accent) 16%, var(--surface))" }}
        >
          <div
            className="h-full rounded-full"
            style={{ width: `${t.tamperResistantPercent}%`, background: "var(--accent)" }}
          />
        </div>
        <span className="min-w-[3rem] text-right text-sm font-semibold">
          {Math.round(t.tamperResistantPercent)}%
        </span>
      </div>
    </Section>
  );
}

/* --------------------------------------------------------------- hardware */

function Hardware({ report }: { report: Report }) {
  const groups: [string, string][] = [
    ["cpu", "Processor"],
    ["memory", "Memory"],
    ["storage", "Storage"],
    ["battery", "Battery"],
  ];

  return (
    <>
      {groups.map(([kind, title]) => {
        const components = report.components.filter((c) => c.kind === kind);
        const consumables = report.consumables.filter((c) => c.kind === kind);
        const items = [...components, ...consumables];
        if (items.length === 0) return null;

        return (
          <Section key={kind} title={title}>
            {kind === "memory" && (
              <div className="mb-4">
                <FactList
                  facts={report.system}
                  fields={[
                    ["memoryInstalled", "Installed"],
                    ["memoryUsable", "System can use"],
                    ["memorySlotsPopulated", "Slots in use"],
                    ["memorySlotsTotal", "Slots on the board"],
                  ]}
                />
              </div>
            )}
            {items.map((item, i) => (
              <div key={`${item.name}-${i}`} className="mb-5">
                {items.length > 1 && (
                  <h3 className="selectable mb-1 text-[15px] font-semibold">{item.name}</h3>
                )}
                <FactList facts={item.facts} fields={DISPLAY_FIELDS[kind] ?? []} />
              </div>
            ))}
          </Section>
        );
      })}

      {report.errors.length > 0 && (
        <Section title="Could not be read">
          <ul className="space-y-2">
            {report.errors.map((e, i) => (
              <li key={i} className="text-sm ink-2">
                {e}
              </li>
            ))}
          </ul>
        </Section>
      )}
    </>
  );
}

/* ----------------------------------------------------------------- checks */

function Checks({ report }: { report: Report }) {
  return (
    <Section title="Consistency checks">
      <p className="mb-4 max-w-3xl ink-2">
        Each of these compares two sources that describe the same thing but arrive by different
        routes. Faking one is easy; faking both to agree is much harder, so disagreement between
        them is worth knowing about.
      </p>
      <ul>
        {report.tamperChecks.map((c) => (
          <CheckRow key={c.id} status={c.status} title={c.title} detail={c.detail} />
        ))}
      </ul>
    </Section>
  );
}

/* --------------------------------------------------------------- findings */

function Findings({ report }: { report: Report }) {
  const order = { critical: 0, warn: 1, info: 2 } as const;
  const sorted = [...report.findings].sort(
    (a, b) => order[a.severity] - order[b.severity],
  );

  return (
    <Section title="What you should know">
      {sorted.length === 0 ? (
        <p style={{ color: "var(--good-ink)" }}>Nothing of concern was found.</p>
      ) : (
        <ul>
          {sorted.map((f, i) => (
            <FindingRow
              key={i}
              severity={f.severity}
              title={f.title}
              detail={f.detail}
              evidence={f.evidence}
            />
          ))}
        </ul>
      )}
    </Section>
  );
}

/* ---------------------------------------------------------------- notices */

function Banner({ tone, text }: { tone: "critical" | "info"; text: string }) {
  const ink = tone === "critical" ? "var(--poor-ink)" : "var(--ink-2)";
  return (
    <div className="mb-5 rounded-lg border-l-[3px] py-2 pl-3" style={{ borderColor: ink }}>
      <p className="text-sm" style={{ color: ink }}>
        {text}
      </p>
    </div>
  );
}

function UnlockNotice({
  ready,
  onElevate,
}: {
  ready: Readiness | null;
  onElevate: () => void;
}) {
  return (
    <div className="surface-2 mb-6 flex flex-wrap items-center justify-between gap-3 rounded-lg border p-3 hairline">
      <p className="text-sm ink-2">
        Drive health is missing because asking a drive about its own condition needs
        permission. Everything else here is complete.
      </p>
      {ready?.canElevate ? (
        <button
          onClick={onElevate}
          className="flex-none rounded-lg px-3 py-1.5 text-sm font-medium text-white"
          style={{ background: "var(--accent)" }}
        >
          {ready.platform === "windows" ? "Restart as administrator" : "Unlock full check"}
        </button>
      ) : (
        <span className="flex-none text-sm ink-3">
          {ready?.platform === "windows"
            ? "Run as administrator for the full check."
            : "Start with sudo for the full check."}
        </span>
      )}
    </div>
  );
}
