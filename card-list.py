#!/usr/bin/env python3

# HEAVILY inspired by https://projectpythia.org/ "cookbook gallery"
import argparse
import concurrent.futures
import json
import sys
import traceback
import urllib.request

import yaml

from unist import *

LAYOUT_STYLE = {
    "display": "inline-block",
    "borderRadius": 8,
    "color": "white",
    "padding": 5,
    "margin": 5,
}

DEFAULT_STYLE = {"background": "#4E66F6", **LAYOUT_STYLE}

styles = {
    "domains": {"background": "#7A77B4", **LAYOUT_STYLE},
    "packages": {"background": "#B83BC0", **LAYOUT_STYLE},
}


def fetch_yaml(url: str):
    print(f"Fetching {url}", file=sys.stderr, flush=True)
    with urllib.request.urlopen(url) as response:
        body = response.read().decode()
    return yaml.load(body, yaml.SafeLoader)


def render_paper(name: str):
    try:
        print(f"Rendering {name}", file=sys.stderr, flush=True)

        raw_base_url = f"https://raw.githubusercontent.com/pollomarzo/{name}/main"
        config_url = f"{raw_base_url}/myst.yml"
        book_url = f"https://pollomarzo.github.io/{name}"

        # Load JB data
        config = fetch_yaml(config_url)
        title = config["project"]["title"]

        # Fetch gallery metadata
        gallery_url = f"{raw_base_url}/_gallery_info.yml"
        gallery_data = fetch_yaml(gallery_url)
        image_name = gallery_data["thumbnail"]
        image_url = f"{raw_base_url}/{image_name}"

        # Build tags
        tags = gallery_data["tags"]

        return {
            "type": "card",
            "url": book_url,
            "children": [
                {"type": "cardTitle", "children": [text(title)]},
                div(
                    [
                        image(image_url),
                        div(
                            [
                                span(
                                    [text(item)],
                                    style=styles.get(name, DEFAULT_STYLE),
                                )
                                for name, items in tags.items()
                                if items is not None
                                for item in items
                            ]
                        ),
                    ],
                ),
            ],
        }
    except Exception as err:
        print(f"\n\nError rendering {name}", file=sys.stderr)
        traceback.print_exception(err, file=sys.stderr)
        return None


def render_papers(pool):
    with open("papers.txt") as f:
        lines = f.read().splitlines()

    parsed_papers = []
    current_year = None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith('#'):
            current_year = line[1:].strip()
        else:
            parsed_papers.append((line, current_year))

    names = [p[0] for p in parsed_papers]
    cards = list(pool.map(render_paper, names))

    results = []
    for (name, year), card in zip(parsed_papers, cards):
        if card is not None:
            results.append({"year": year, "card": card})

    return results


def run_directive(name, data):
    assert name == "paper-cards"
    subset = data.get("options", {}).get("subset")
    return [{"type": "paper-cards", "subset": subset, "children": []}]


def run_transform(name, data):
    with concurrent.futures.ThreadPoolExecutor() as pool:
        # Find our cookbook nodes in the AST
        cookbook_nodes = find_all_by_type(data, "paper-cards")

        # In-place mutate the AST to replace cookbook nodes with card grids
        all_papers = render_papers(pool)

        # Mutate our cookbook nodes in-place
        for node in cookbook_nodes:
            subset = node.get("subset")
            children = [
                p["card"]
                for p in all_papers
                if subset is None or str(p["year"]) == str(subset)
            ]
            node.clear()
            node.update(grid([1, 1, 2, 3], children))
            node["children"] = children

    return data


paperGalleryDirective = {
    "name": "paper-cards",
    "doc": "An example directive for embedding a Pythia cookbook gallery.",
    "options": {
        "subset": {"type": "string"},
    },
}
paperGalleryTransform = {
    "stage": "document",
}

PLUGIN_SPEC = {
    "name": "Paper Gallery",
    "directives": [paperGalleryDirective],
    "transforms": [paperGalleryTransform],
}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--role")
    group.add_argument("--directive")
    group.add_argument("--transform")
    args = parser.parse_args()

    if args.directive:
        data = json.load(sys.stdin)
        json.dump(run_directive(args.directive, data), sys.stdout)
    elif args.transform:
        data = json.load(sys.stdin)
        json.dump(run_transform(args.transform, data), sys.stdout)
    elif args.role:
        raise NotImplementedError
    else:
        json.dump(PLUGIN_SPEC, sys.stdout)
