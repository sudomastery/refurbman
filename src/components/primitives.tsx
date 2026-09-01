/**
 * The small pieces every view is built from.
 *
 * The rule these all obey: no verdict is ever carried by colour alone. The good
 * green and the poor red sit 4.1 apart under deuteranopia, so for roughly one
 * man in twelve they are the same colour, and this application's whole job is
 * to say whether something is fine. Every verdict therefore carries a shape and
 * a word too, and none of the three is load-bearing on its own.
 */

import type { ReactNode } from "react";
import type { CheckStatus, Fact, Severity, Verdict } from "../lib/types";
import { factText } from "../lib/types";

const VERDICT: Record<Verdict, { word: string; mark: string; ink: string; bar: string }> = {
  good: { word: "Good", mark: "✓", ink: "var(--good-ink)", bar: "var(--good)" },
  fair: { word: "Fair", mark: "!", ink: "var(--fair-ink)", bar: "var(--warning)" },
  poor: { word: "Poor", mark: "✗", ink: "var(--poor-ink)", bar: "var(--critical)" },
  unknown: { word: "Not known", mark: "?", ink: "var(--ink-3)", bar: "var(--neutral)" },
};

export function verdictInk(v: Verdict): string {
  return VERDICT[v].ink;
}

export function Badge({ verdict }: { verdict: Verdict }) {
  const v = VERDICT[verdict];
  return (
    <span
      className="inline-flex flex-none items-center gap-1 rounded-full border px-2 py-[2px] text-[11px] font-bold uppercase tracking-wider"
      style={{ color: v.ink, borderColor: "currentColor" }}
    >
      <span aria-hidden="true">{v.mark}</span>
      {v.word}
    </span>
  );
}

/**
 * A horizontal meter. The unfilled track is a lighter step of the fill's own
 * hue, so the state reads across the whole bar rather than only where the fill
 * stops.
 *
 * A ring gauge was the obvious choice here and is the wrong one: for a single
 * percentage it is a two-slice pie, which is a harder read than a bar for no
 * gain.
 */
export function Meter({
  label,
  percent,
  verdict,
}: {
  label: string;
  percent: number | null;
  verdict: Verdict;
}) {
  const v = VERDICT[verdict];
  // A figure we do not believe gets a hatched fill. A solid bar at 100% reads
  // as excellent at a glance, which is the opposite of what Not known means,
  // and the badge alone is far too quiet to undo that first impression.
  const doubted = verdict === "unknown" && percent !== null;

  return (
    <div className="mt-3">
      <div className="mb-1 text-xs ink-3">{label}</div>
      <div className="flex items-center gap-3">
        {percent === null ? (
          <>
            <div className="meter-unmeasured h-[9px] flex-1 rounded-full" />
            <div className="min-w-[5.5rem] text-right text-xs ink-3">not reported</div>
          </>
        ) : (
          <>
            <div
              className="h-[9px] flex-1 overflow-hidden rounded-full"
              style={{ background: `color-mix(in oklab, ${v.bar} 16%, var(--surface))` }}
              role="meter"
              aria-valuenow={Math.round(percent)}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-label={label}
            >
              <div
                className={`h-full rounded-full ${doubted ? "meter-doubted" : ""}`}
                style={{
                  width: `${Math.max(0, Math.min(100, percent))}%`,
                  background: doubted ? undefined : v.bar,
                }}
              />
            </div>
            <div className="min-w-[5.5rem] text-right">
              <span className="text-sm font-semibold">{Math.round(percent)}%</span>
              {doubted && (
                <span className="block text-[10px] font-bold uppercase tracking-wider ink-3">
                  claimed
                </span>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

const TRUST_INK: Record<number, string> = {
  4: "var(--good-ink)",
  3: "#1f6f8b",
  2: "#3a5ea8",
  1: "var(--ink-3)",
  0: "var(--fair-ink)",
};

/**
 * The provenance chip. Deliberately quiet: it qualifies a reading, it is not
 * the reading. Its tooltip carries the literal source so a sceptic can go and
 * check the number by hand.
 */
export function Chip({ fact }: { fact: Fact }) {
  return (
    <span
      title={fact.source}
      className="flex-none cursor-help rounded border px-[5px] py-[1px] text-[10px] font-bold uppercase tracking-wider"
      style={{ color: TRUST_INK[fact.trust] ?? "var(--ink-3)", borderColor: "currentColor" }}
    >
      {fact.trustLabel}
    </span>
  );
}

export function Row({ label, fact }: { label: string; fact: Fact }) {
  return (
    <div className="flex items-baseline gap-3 border-b py-[6px] hairline last:border-0">
      <div className="w-40 flex-none text-[13px] ink-3">{label}</div>
      <div className="flex flex-1 items-baseline justify-between gap-3">
        <span className="selectable break-words font-medium">{factText(fact)}</span>
        <Chip fact={fact} />
      </div>
    </div>
  );
}

export function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mb-9">
      <h2 className="mb-3 border-b pb-1 text-[12px] font-bold uppercase tracking-[0.12em] ink-3 hairline">
        {title}
      </h2>
      {children}
    </section>
  );
}

export function Card({ children }: { children: ReactNode }) {
  return (
    <article className="surface-2 rounded-xl border p-4 hairline">{children}</article>
  );
}

const CHECK: Record<CheckStatus, { mark: string; word: string; ink: string }> = {
  pass: { mark: "✓", word: "Passed", ink: "var(--good-ink)" },
  suspicious: { mark: "!", word: "Worth a look", ink: "var(--fair-ink)" },
  fail: { mark: "✗", word: "Failed", ink: "var(--poor-ink)" },
  skipped: { mark: "-", word: "Not checked", ink: "var(--ink-3)" },
};

export function CheckRow({ status, title, detail }: { status: CheckStatus; title: string; detail: string }) {
  const c = CHECK[status];
  return (
    <li className="flex gap-3 border-b py-[10px] hairline last:border-0">
      <span aria-hidden="true" className="w-5 flex-none text-center font-bold" style={{ color: c.ink }}>
        {c.mark}
      </span>
      <div className="min-w-0">
        <p className="text-[14px] font-semibold">
          {title}
          <span
            className="ml-2 rounded border px-[5px] py-[1px] text-[10px] font-bold uppercase tracking-wider"
            style={{ color: c.ink, borderColor: "currentColor" }}
          >
            {c.word}
          </span>
        </p>
        {status !== "pass" && <p className="mt-1 max-w-3xl text-[13px] ink-2">{detail}</p>}
      </div>
    </li>
  );
}

const SEVERITY: Record<Severity, { mark: string; word: string; ink: string }> = {
  critical: { mark: "✗", word: "Serious", ink: "var(--poor-ink)" },
  warn: { mark: "!", word: "Worth knowing", ink: "var(--fair-ink)" },
  info: { mark: "i", word: "For information", ink: "var(--ink-3)" },
};

export function FindingRow({
  severity,
  title,
  detail,
  evidence,
}: {
  severity: Severity;
  title: string;
  detail: string;
  evidence?: string | null;
}) {
  const s = SEVERITY[severity];
  return (
    <li className="mb-4 border-l-[3px] py-1 pl-3" style={{ borderColor: s.ink }}>
      <p className="font-semibold">
        <span aria-hidden="true" className="mr-2 font-bold" style={{ color: s.ink }}>
          {s.mark}
        </span>
        <span
          className="mr-2 rounded border px-[5px] py-[1px] text-[10px] font-bold uppercase tracking-wider"
          style={{ color: s.ink, borderColor: "currentColor" }}
        >
          {s.word}
        </span>
        {title}
      </p>
      <p className="mt-1 max-w-3xl text-[14px] ink-2">{detail}</p>
      {evidence && (
        <p className="selectable mt-1 break-words font-mono text-[11px] ink-3">{evidence}</p>
      )}
    </li>
  );
}
