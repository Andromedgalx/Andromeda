#!/usr/bin/env python3
"""
web_search - minimal web search for Andromeda (dependency-light)

Usage:
  web_search "query" [--count N] [--prefer-youtube] [--summary] [--titles N]

Examples:
  web_search "daft punk one more time" --count 6 --prefer-youtube
  web_search "linux kernel" --count 5
  web_search "important paper" --count 3 --summary
"""

from __future__ import annotations
import sys
import argparse
import requests
import re
import html
import time
from urllib.parse import quote_plus, urlparse, unquote

DDG_HTML = "https://html.duckduckgo.com/html/?q={q}"
USER_AGENT = "Andromeda-WebSearch/1.0 (+local)"
REQUEST_TIMEOUT = 7  # seconds
MAX_TITLE_BYTES = 20_000  # how many bytes to read when fetching a page title
OLLAMA_API = "http://localhost:11434/api/generate"

def parse_args():
    p = argparse.ArgumentParser(description="Minimal web search for Andromeda")
    p.add_argument("query", nargs="+", help="Search query (wrap in quotes)")
    p.add_argument("--count", type=int, default=5, help="How many results to return (default 5)")
    p.add_argument("--prefer-youtube", action="store_true", help="Prefer YouTube links first")
    p.add_argument("--summary", action="store_true", help="Ask local Ollama for a short summary of the top result(s)")
    p.add_argument("--titles", type=int, default=0, help="Fetch page titles for the top N results (0 = none)")
    return p.parse_args()

def fetch_ddg(query: str) -> str:
    url = DDG_HTML.format(q=quote_plus(query))
    headers = {"User-Agent": USER_AGENT}
    resp = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()
    return resp.text

def extract_links_from_ddg(html_text: str, max_links: int = 100) -> list[str]:
    # naive link extraction: find href="..."
    # also try to decode /l/?u= redirect links
    hrefs = re.findall(r'href="([^"]+)"', html_text)
    results = []
    seen = set()
    for href in hrefs:
        href = html.unescape(href)
        if href.startswith("/l/?kh=") or href.startswith("/l/?"):
            # attempt to extract u= param
            m = re.search(r'u=([^&]+)', href)
            if m:
                try:
                    candidate = unquote(m.group(1))
                    if candidate.startswith("http"):
                        href = candidate
                except Exception:
                    pass
        # ignore DuckDuckGo internal links
        if href.startswith("/") and not href.startswith("http"):
            continue
        if not (href.startswith("http://") or href.startswith("https://")):
            continue
        if href not in seen:
            seen.add(href)
            results.append(href)
        if len(results) >= max_links:
            break
    return results

def fetch_title(url: str) -> str:
    headers = {"User-Agent": USER_AGENT}
    try:
        resp = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT, stream=True)
        # read up to MAX_TITLE_BYTES bytes
        content = b""
        for chunk in resp.iter_content(1024):
            content += chunk
            if len(content) > MAX_TITLE_BYTES:
                break
        text = content.decode(errors="ignore")
        m = re.search(r'<title[^>]*>(.*?)</title>', text, re.IGNORECASE | re.DOTALL)
        if m:
            title = re.sub(r'\s+', ' ', html.unescape(m.group(1))).strip()
            return title[:200]
    except Exception:
        pass
    # fallback to domain
    try:
        parsed = urlparse(url)
        return f"{parsed.netloc}{parsed.path}"[:200]
    except Exception:
        return url[:200]

def call_ollama_for_summary(text: str, max_tokens: int = 400) -> str:
    # best-effort: local Ollama API; if unavailable, return empty
    try:
        payload = {
            "model": "mixtral:latest",
            "prompt": text,
            "stream": False
        }
        headers = {"Content-Type": "application/json"}
        r = requests.post(OLLAMA_API, json=payload, headers=headers, timeout=8)
        r.raise_for_status()
        j = r.json()
        # try a few fields
        for k in ("response", "text", "result"):
            if k in j and isinstance(j[k], str) and j[k].strip():
                return j[k].strip()
        # fallback: stringify
        return str(j)[:1000]
    except Exception:
        return ""

def main():
    args = parse_args()
    query = " ".join(args.query).strip()
    if not query:
        print("No query provided", file=sys.stderr); sys.exit(1)

    try:
        body = fetch_ddg(query)
    except Exception as e:
        print("Error: failed to contact search engine:", e, file=sys.stderr)
        sys.exit(2)

    links = extract_links_from_ddg(body, max_links=200)
    if not links:
        # fallback to youtube search url
        print("No results found; returning YouTube search URL")
        print("1) https://www.youtube.com/results?search_query=" + quote_plus(query))
        sys.exit(0)

    # optionally prefer Youtube links
    yt_links = [u for u in links if ("youtube.com" in u or "youtu.be" in u)]
    chosen = []
    if args.prefer_youtube and yt_links:
        chosen.extend(yt_links[:args.count])

    # fill remaining slots with first non-duplicate links
    for u in links:
        if u in chosen: continue
        chosen.append(u)
        if len(chosen) >= args.count:
            break

    # optionally fetch titles for top N
    titles = {}
    n_titles = max(0, min(args.titles, len(chosen)))
    for i, url in enumerate(chosen[:n_titles]):
        titles[url] = fetch_title(url)

    # Print numbered results with titles when available
    for i, url in enumerate(chosen[:args.count], start=1):
        title = titles.get(url, "")
        if title:
            print(f"{i}) {title} — {url}")
        else:
            print(f"{i}) {url}")

    # Optional: summary (useful if user asked)
    if args.summary:
        # summarize the top result(s) (concise)
        summary_input = f"Summarize the content of the following URLs briefly (3-4 sentences each):\n" + "\n".join(chosen[: min(3, len(chosen))])
        s = call_ollama_for_summary(summary_input)
        if s:
            print("\n--- Summary (from local Ollama) ---")
            print(s)
        else:
            print("\n--- Summary not available (Ollama unreachable or returned nothing) ---")

if __name__ == "__main__":
    main()
