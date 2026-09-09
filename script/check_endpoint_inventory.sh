#!/usr/bin/env bash
# Diffs this venue's committed endpoint inventory against the vendor's CURRENT published
# documentation index, and reports anything that appeared or vanished.
#
# Why an index diff and not something richer:
#
# `dp_exchange_core`'s vendor-change design doc audited what would have caught each way
# five vendors' documentation turned out to be wrong. A CHANGELOG diff caught nothing
# across the whole sample. An INDEX diff was the only mechanism that ever fired. The same
# sitemap search on `developer.webull.com` later found a per-endpoint rate-limit table that
# had existed for weeks while this family declared a ceiling five times too permissive
# there; on `developer.gemini.com` a spec diff found a WebSocket channel withdrawn with no
# changelog entry. The mechanism keeps paying.
#
# **This venue does not publish a specification for Advanced Trade**, so unlike
# `dp_exchange_gemini` there is no operation list to compare. What it does publish is a
# `sitemap.xml`, and its `api-reference/advanced-trade-api/rest-api/` pages are one per
# endpoint — so the set of those pages is the index, and comparing it costs exactly one
# HTTP request.
#
# Deliberately NOT re-deriving `endpoints-enumerated.tsv`. That file's method — reading
# each page's own `pageMetadata.openapi` field — meant fetching 806 pages, which is a
# reasonable thing to do once by hand and a rude thing to do to a vendor every week.
#
# A difference is a NOTICE, not a build failure. A page appearing may mean an
# `:unsupported` declaration in `capabilities/0` is now false; one vanishing may mean a
# claim this package makes has gone stale. Both need a person.
#
# Documentation index only. Never a venue API: tier-2 tests hit live endpoints and must
# never run on a schedule.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMITTED="$ROOT/docs/reference/coinbase/endpoints-enumerated.tsv"
WORK="$ROOT/tmp/inventory_check"
SITEMAP="https://docs.cdp.coinbase.com/sitemap.xml"

rm -rf "$WORK"
mkdir -p "$WORK"

# `tr -d '\r'` guards the CRLF trap that made a sibling checker report every entry as both
# added and removed at once.
curl -sL --max-time 60 "$SITEMAP" | tr -d '\r' \
  | grep -oE "api-reference/advanced-trade-api/rest-api/[^<[:space:]]*" \
  | sed 's|api-reference/||' \
  | grep -v '/introduction$' \
  | sort -u > "$WORK/now.txt"

if [ ! -s "$WORK/now.txt" ]; then
  echo "  UNREACHABLE  the sitemap returned no Advanced Trade REST pages — not treating"
  echo "               that as a change. A vendor being down is not a vendor changing."
  exit 0
fi

grep "^advanced-trade-api/rest-api/" "$COMMITTED" | cut -f1 | sort -u > "$WORK/committed.txt"

added=$(comm -13 "$WORK/committed.txt" "$WORK/now.txt")
removed=$(comm -23 "$WORK/committed.txt" "$WORK/now.txt")

echo "== coinbase Advanced Trade REST endpoint pages vs. the committed inventory"

if [ -z "$added" ] && [ -z "$removed" ]; then
  echo "  OK       $(wc -l < "$WORK/now.txt" | tr -d ' ') endpoint pages, unchanged"
  echo
  echo "The committed inventory matches the vendor's current documentation index."
  exit 0
fi

echo "  CHANGED"
if [ -n "$added" ]; then
  echo "    APPEARED since the committed inventory was taken:"
  printf '      %s\n' $added
  echo "      -> a capabilities/0 :unsupported declaration may now be FALSE."
fi
if [ -n "$removed" ]; then
  echo "    VANISHED since the committed inventory was taken:"
  printf '      %s\n' $removed
  echo "      -> a claim this package makes may now rest on nothing."
fi

echo
echo "This is a NOTICE, not a build failure. Read the vendor's page, decide what the change"
echo "means for what this package CLAIMS, fix the claim if it is now wrong, and only then"
echo "update docs/reference/coinbase/endpoints-enumerated.tsv with today's date. Updating"
echo "the inventory first turns this check into a rubber stamp."
exit 1
