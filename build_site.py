import argparse
import shutil
import subprocess
import yaml
import os
from pathlib import Path

# Configuration
CONFIG_FILE = Path("journal.yml")
NEXUS_DIR = Path("nexus")
CONTENT_DIR = NEXUS_DIR / "content" / "papers"
MYST_EXEC = "myst"
HOME_MD = NEXUS_DIR / "home.md"

def clone_repo(repo_url, clone_path):
    """Clones a repo into a specific path."""
    if clone_path.exists():
        print(f"Path {clone_path} exists. Skipping clone (assuming it's up to date or manual).")
        return

    print(f"Cloning {repo_url} into {clone_path}...")
    subprocess.run(
        ["git", "clone", "--depth", "1", repo_url, str(clone_path)],
        check=True,
    )

def parse_frontmatter(file_path):
    """Parses YAML frontmatter from a markdown file."""
    if not file_path.exists():
        # Try adding .md extension
        file_path = Path(str(file_path) + ".md")
        if not file_path.exists():
             print(f"Warning: File {file_path} not found for frontmatter parsing.")
             return {}

    with open(file_path, "r") as f:
        content = f.read()
    
    if content.startswith("---"):
        try:
            parts = content.split("---", 2)
            if len(parts) >= 3:
                return yaml.safe_load(parts[1])
        except Exception as e:
            print(f"Error parsing frontmatter for {file_path}: {e}")
    return {}

def create_myst_config(paper_dir, main_file):
    """Creates a myst.yml for a single article using frontmatter."""
    frontmatter = parse_frontmatter(paper_dir / main_file)
    
    # Use title from frontmatter or fallback to dir name
    title = frontmatter.get("title", paper_dir.name)
    
    config = {
        "version": 1,
        "project": {
            "id": paper_dir.name,
            "title": title,
            "main": main_file if main_file.endswith(".md") else f"{main_file}.md",
        },
        "site": {
            "template": "article-theme"
        }
    }
    
    if "authors" in frontmatter:
        config["project"]["authors"] = frontmatter["authors"]

    with open(paper_dir / "myst.yml", "w") as f:
        yaml.dump(config, f)

def build_paper(paper_dir, repo_name):
    """Runs myst build --html on the paper directory and copies output."""
    print(f"Building {paper_dir}...")
    
    # Set BASE_URL so Myst generates correct asset paths
    # For GitHub Pages: SITE_PREFIX=/scholar-nexus (from env), so BASE_URL=/scholar-nexus/papers/{repo_name}
    # For local dev: SITE_PREFIX empty, so BASE_URL=/papers/{repo_name}
    env = os.environ.copy()
    site_prefix = os.environ.get("SITE_PREFIX", "")
    env["BASE_URL"] = f"{site_prefix}/papers/{repo_name}"
    
    subprocess.run(
        [MYST_EXEC, "build", "--html"],
        cwd=paper_dir,
        check=True,
        env=env
    )
    
    # Copy built files to static location
    output_dir = NEXUS_DIR / "papers" / repo_name
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        paper_dir / "_build" / "html",
        output_dir
    )

def generate_homepage(papers):
    """Generates a simple HTML homepage."""
    
    # Read home.md content
    home_content_md = ""
    if HOME_MD.exists():
        with open(HOME_MD, "r") as f:
            home_content_md = f.read()
            # Strip frontmatter if present
            if home_content_md.startswith("---"):
                 parts = home_content_md.split("---", 2)
                 if len(parts) >= 3:
                     home_content_md = parts[2].strip()
    
    # Simple markdown to HTML conversion
    home_content_html = ""
    lines = home_content_md.split("\n")
    in_paragraph = False
    
    for line in lines:
        line = line.strip()
        if not line:
            if in_paragraph:
                home_content_html += "</p>\n"
                in_paragraph = False
            continue
            
        if line.startswith("# "):
            if in_paragraph:
                home_content_html += "</p>\n"
                in_paragraph = False
            home_content_html += f"<h1>{line[2:]}</h1>\n"
        elif line.startswith("## "):
            if in_paragraph:
                home_content_html += "</p>\n"
                in_paragraph = False
            home_content_html += f"<h2>{line[3:]}</h2>\n"
        else:
            if not in_paragraph:
                home_content_html += "<p>"
                in_paragraph = True
            else:
                home_content_html += " "
            home_content_html += line
    
    if in_paragraph:
        home_content_html += "</p>\n"
    
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Scholar Nexus</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ font-family: 'Georgia', serif; max-width: 900px; margin: 0 auto; padding: 2rem; background-color: #fafbfc; line-height: 1.7; color: #24292e; }}
        h1 {{ color: #1a1a1a; margin-top: 2rem; margin-bottom: 1rem; font-size: 1.8em; font-weight: 600; }}
        h2 {{ color: #2a2a2a; margin-top: 1.5rem; margin-bottom: 0.75rem; font-size: 1.4em; font-weight: 600; }}
        p {{ margin-bottom: 1rem; font-weight: normal; font-size: 1rem; }}
        .content {{ margin-bottom: 3rem; }}
        .papers {{ margin-top: 3rem; }}
        .papers h2 {{ border-bottom: 2px solid #e1e4e8; padding-bottom: 0.5rem; }}
        .paper-card {{ background: white; border: 1px solid #e1e4e8; border-radius: 6px; padding: 1.5rem; margin-bottom: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.05); transition: all 0.2s; }}
        .paper-card:hover {{ box-shadow: 0 4px 12px rgba(0,0,0,0.1); border-color: #0366d6; }}
        .paper-title {{ margin: 0 0 0.5rem 0; font-size: 1.2rem; font-weight: 600; }}
        .paper-title a {{ text-decoration: none; color: #0366d6; }}
        .paper-title a:hover {{ text-decoration: underline; }}
        .paper-authors {{ color: #586069; font-style: italic; font-size: 0.95rem; font-weight: normal; }}
    </style>
</head>
<body>
    <div class="content">
        {home_content_html}
    </div>
    
    <div class="papers">
        <h2>Latest Papers</h2>
"""
    
    for paper in papers:
        repo_url = paper["repo"]
        main_file = paper["main_file"]
        repo_name = repo_url.split("/")[-1]
        if repo_name.endswith(".git"):
            repo_name = repo_name[:-4]
        
        paper_dir = CONTENT_DIR / repo_name
        frontmatter = parse_frontmatter(paper_dir / main_file)
        
        title = frontmatter.get("title", repo_name)
        title = title.replace("\n", " ")
        
        authors_list = frontmatter.get("authors", [])
        authors_str = ""
        if authors_list:
            names = []
            for a in authors_list:
                if isinstance(a, dict):
                    names.append(a.get("name", "Unknown"))
                else:
                    names.append(str(a))
            authors_str = ", ".join(names)
        
        link = f"papers/{repo_name}/index.html"
        
        html_content += f"""
        <div class="paper-card">
            <h3 class="paper-title"><a href="{link}">{title}</a></h3>
            <div class="paper-authors">{authors_str}</div>
        </div>
"""

    html_content += """
    </div>
</body>
</html>
"""
    
    with open(NEXUS_DIR / "index.html", "w") as f:
        f.write(html_content)

def main():
    parser = argparse.ArgumentParser(description="Build the Scholar Nexus site.")
    parser.add_argument("--dev", action="store_true", help="Dev mode: process only first paper.")
    args = parser.parse_args()

    # Ensure directories exist
    (NEXUS_DIR / CONTENT_DIR).mkdir(parents=True, exist_ok=True)

    with open(CONFIG_FILE, "r") as f:
        config = yaml.safe_load(f)

    papers = config.get("papers", [])
    if args.dev and papers:
        papers = papers[:1]

    for paper in papers:
        repo_url = paper["repo"]
        main_file = paper["main_file"]
        repo_name = repo_url.split("/")[-1]
        if repo_name.endswith(".git"):
            repo_name = repo_name[:-4]
        
        paper_dir = CONTENT_DIR / repo_name
        
        clone_repo(repo_url, paper_dir)
        create_myst_config(paper_dir, main_file)
        build_paper(paper_dir, repo_name)

    generate_homepage(papers)
    print("Build complete.")

if __name__ == "__main__":
    main()
