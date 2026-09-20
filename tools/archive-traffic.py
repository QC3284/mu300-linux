#!/usr/bin/env python3
"""
Archive repository traffic (views, clones, referrers) and release download statistics.
Merges new data into docs/stats/traffic.json, updates README.md between markers,
and regenerates docs/STATS.md.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone


def get_token():
    token = os.environ.get("TRAFFIC_TOKEN") or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        return token
    try:
        return subprocess.check_output(["gh", "auth", "token"], stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return None


def gh_get(endpoint, repo, token=None):
    url = f"https://api.github.com/repos/{repo}{endpoint}"
    headers = {
        "User-Agent": "mu300-traffic-archiver",
        "Accept": "application/vnd.github.v3+json",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"Warning: HTTP {e.code} for {url}\n")
        return None
    except Exception as e:
        sys.stderr.write(f"Warning: Failed to fetch {url}: {e}\n")
        return None


def format_size(bytes_num):
    if bytes_num < 1024:
        return f"{bytes_num} B"
    elif bytes_num < 1024 * 1024:
        return f"{bytes_num / 1024:.1f} KB"
    elif bytes_num < 1024 * 1024 * 1024:
        return f"{bytes_num / (1024 * 1024):.1f} MB"
    else:
        return f"{bytes_num / (1024 * 1024 * 1024):.2f} GB"


def main():
    repo = os.environ.get("GITHUB_REPOSITORY", "dikeckaan/mu300-linux")
    token = get_token()
    top = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    stats_dir = os.path.join(top, "docs", "stats")
    os.makedirs(stats_dir, exist_ok=True)

    json_path = os.path.join(stats_dir, "traffic.json")
    data = {
        "repository": repo,
        "views_daily": {},
        "clones_daily": {},
        "referrers": [],
        "last_updated": None,
    }
    if os.path.exists(json_path):
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                data["views_daily"] = loaded.get("views_daily", {})
                data["clones_daily"] = loaded.get("clones_daily", {})
                data["referrers"] = loaded.get("referrers", [])
        except Exception as e:
            sys.stderr.write(f"Warning: Could not read existing json: {e}\n")

    # Fetch live API data
    repo_meta = gh_get("", repo, token) or {}
    views_res = gh_get("/traffic/views", repo, token) or {}
    clones_res = gh_get("/traffic/clones", repo, token) or {}
    referrers_res = gh_get("/traffic/popular/referrers", repo, token) or []
    releases_res = gh_get("/releases", repo, token) or []

    # Merge views
    for item in views_res.get("views", []):
        day = item["timestamp"][:10]
        cur = data["views_daily"].get(day, {"count": 0, "uniques": 0})
        data["views_daily"][day] = {
            "count": max(cur.get("count", 0), item.get("count", 0)),
            "uniques": max(cur.get("uniques", 0), item.get("uniques", 0)),
        }

    # Merge clones
    for item in clones_res.get("clones", []):
        day = item["timestamp"][:10]
        cur = data["clones_daily"].get(day, {"count": 0, "uniques": 0})
        data["clones_daily"][day] = {
            "count": max(cur.get("count", 0), item.get("count", 0)),
            "uniques": max(cur.get("uniques", 0), item.get("uniques", 0)),
        }

    if referrers_res:
        data["referrers"] = referrers_res

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    data["last_updated"] = now_iso

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    print(f"Updated {json_path}")

    # Calculate totals
    total_views = sum(v["count"] for v in data["views_daily"].values())
    total_unique_views = sum(v["uniques"] for v in data["views_daily"].values())
    total_clones = sum(c["count"] for c in data["clones_daily"].values())
    total_unique_cloners = sum(c["uniques"] for c in data["clones_daily"].values())

    total_downloads = 0
    kernel_downloads = 0
    rootfs_downloads = 0
    release_rows = []

    for r in releases_res:
        tag = r.get("tag_name")
        first = True
        for a in r.get("assets", []):
            cnt = a.get("download_count", 0)
            sz = format_size(a.get("size", 0))
            name = a.get("name")
            total_downloads += cnt
            if "kernel" in name.lower():
                kernel_downloads += cnt
            elif "rootfs" in name.lower() or "ubuntu" in name.lower() or "openwrt" in name.lower():
                rootfs_downloads += cnt
            tag_label = f"**{tag}**" if first else ""
            release_rows.append(f"| {tag_label} | `{name}` | {sz} | **{cnt}** |")
            first = False

    # Generate the Markdown block for README.md and docs/STATS.md
    stars = repo_meta.get("stargazers_count", 0)
    forks = repo_meta.get("forks_count", 0)
    fork_ratio = (forks / max(1, stars)) * 100

    stats_block_lines = [
        "<!-- STATS:START -->",
        f"> *Last updated: **{now_iso}** (tracked automatically via GitHub Actions)*",
        "",
        "### Overview",
        "",
        "| Metric | Count | Details |",
        "|---|---|---|",
        f"| ⭐ **Stars** | **{stars}** | Stargazers |",
        f"| 🍴 **Forks** | **{forks}** | Forks ({fork_ratio:.0f}% fork-to-star ratio) |",
        f"| 📥 **Release Asset Downloads** | **{total_downloads}** | {kernel_downloads + rootfs_downloads} OS/Kernel images, {total_downloads - (kernel_downloads + rootfs_downloads)} checksums |",
        f"| 👥 **Page Views (Archived)** | **{total_views:,}** | ~{total_unique_views:,} unique visitors |",
        f"| 💻 **Git Clones (Archived)** | **{total_clones:,}** | ~{total_unique_cloners:,} unique cloners |",
        "",
        "### Daily Traffic & Git Clones",
        "",
        "| Date | Page Views | Unique Visitors | Git Clones | Unique Cloners |",
        "|---|---|---|---|---|",
    ]

    all_dates = sorted(set(list(data["views_daily"].keys()) + list(data["clones_daily"].keys())), reverse=True)
    for d in all_dates:
        v = data["views_daily"].get(d, {"count": 0, "uniques": 0})
        c = data["clones_daily"].get(d, {"count": 0, "uniques": 0})
        if v["count"] > 0 or c["count"] > 0:
            stats_block_lines.append(f"| **{d}** | {v['count']} | {v['uniques']} | {c['count']} | {c['uniques']} |")

    if data.get("referrers"):
        stats_block_lines.extend([
            "",
            "### Top Referring Sites",
            "",
            "| Referrer | Total Views | Unique Visitors |",
            "|---|---|---|",
        ])
        for ref in data["referrers"]:
            stats_block_lines.append(f"| {ref.get('referrer')} | {ref.get('count')} | {ref.get('uniques')} |")

    stats_block_lines.extend([
        "",
        "### Release Downloads Breakdown",
        "",
        "| Release | Asset | Size | Downloads |",
        "|---|---|---|---|",
    ])
    stats_block_lines.extend(release_rows)
    stats_block_lines.append("<!-- STATS:END -->")
    stats_block_content = "\n".join(stats_block_lines)

    # 1. Update README.md
    readme_path = os.path.join(top, "README.md")
    if os.path.exists(readme_path):
        with open(readme_path, "r", encoding="utf-8") as f:
            readme_text = f.read()
        pattern = r"<!-- STATS:START -->.*?<!-- STATS:END -->"
        if re.search(pattern, readme_text, re.DOTALL):
            new_readme = re.sub(pattern, stats_block_content, readme_text, flags=re.DOTALL)
            with open(readme_path, "w", encoding="utf-8") as f:
                f.write(new_readme)
            print(f"Updated {readme_path}")
        else:
            sys.stderr.write("Notice: README.md does not contain <!-- STATS:START --> markers.\n")

    # 2. Update docs/STATS.md
    md_path = os.path.join(top, "docs", "STATS.md")
    stats_md_lines = [
        f"# Repository & Community Statistics — `{repo}`",
        "",
        stats_block_content,
        "",
        "### Star History",
        "",
        f"[![Star History Chart](https://api.star-history.com/svg?repos={repo}&type=Date)](https://star-history.com/#{repo}&Date)",
    ]
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("\n".join(stats_md_lines) + "\n")
    print(f"Updated {md_path}")


if __name__ == "__main__":
    main()
