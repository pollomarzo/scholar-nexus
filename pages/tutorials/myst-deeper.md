---
title: MyST - a slightly deeper dive
description: An overview on the MyST markdown engine
---

# Some more technical details

This page includes additional content that may be useful to you if you're looking to understand how our setup with mystmd works behind the scenes. The most up-to-date and complete documentation is and will always be the official [MyST docs](https://mystmd.org/guide); we understand it may look daunting to beginners, so this info should help you get on your feet quickly.

## What is MyST

If you've ever written a README on GitHub or formatted a message on Discord or slack, you've probably used Markdown. It's a dead simple way to add formatting (**bold**, *italic* or `code`) to text, while keeping it readable. MyST takes markdown and adds a few **very helpful** pieces for scientific and technical writing, and has a great community around it.

MyST is **not** the only project for this: Quarto has similar aims. We chose myst because of some specific features that help our aim (e.g. myst configuration inheritance, native AST conversion), and because it's the native format for Jupyter Book and is developed under Project Jupyter; if you already know Quarto, you'll see that the evolution is more converging than it may seem.

## How MyST Configuration Works

The template repository we prepared for the Impact Scholar Program micropublication uses MyST's configuration inheritance system. The `myst.yml` file extends shared configurations:

```yaml
extends:
  - https://raw.githubusercontent.com/pollomarzo/scholar-nexus/main/nexus.yml
  - https://raw.githubusercontent.com/pollomarzo/scholar-nexus-paper-config/main/isp-micropublication-2025.yml
```

- **`nexus.yml`**: Provides Scholar Nexus branding and navigation
- **`isp-micropublication-2025.yml`**: Venue-specific settings (license, funding acknowledgment)

These base configs also extend `paper-base.yml`, which configures:
- Thumbnail location for the paper gallery
- Typst PDF export settings
- Site theme options

See [MyST Configuration Documentation](https://mystmd.org/guide/configuration) for details.

### Frontmatter

For each page (like `index.md`), page frontmatter defines page-level metadata:

```yaml
---
title: Your Paper Title
abstract: |
    Your abstract here...
---
```

This is separate from `myst.yml` project metadata. The `title` in `myst.yml` sets the browser tab title, while the frontmatter `title` sets the heading displayed on the page (you may have noticed there's no main heading in the markdown body). See [MyST Frontmatter Guide](https://mystmd.org/guide/frontmatter) for more.

### Citations

The absolute easiest way to cite is to use the DOI like `[](doi:someDOI/w1thNumb3rs)`. But what if something doesn't have a DOI? You can include a bibliography file.

Here's our suggested workflow for handling citations, fully powered by open-source tools:
1. Use Zotero as your *reference manager*. You can import from web pages directly by installing its browser extension, or add items manually otherwise
2. Install the [better bibtex](https://retorque.re/zotero-better-bibtex/) plugin to enable some great features, plus
3. Use the [automatic export](https://retorque.re/zotero-better-bibtex/exporting/auto/) feature to create your `bib.bib` bibliography file

Once your `bib.bib` file is ready, make sure it's imported in your `myst.yml`, and then cite using:
- `@citationKey` for inline citations
- `[@citationKey]` for parenthetical citations

See [MyST Citations Guide](https://mystmd.org/guide/citations).

### Figures

Figures use MyST's figure directive:

```markdown
​```{figure} figure.png
:name: figure-main
:alt: Description for accessibility

**A.** Panel A description.
**B.** Panel B description.
​```
```

Reference in text with `@figure-main` or `@figure-main A`. See [MyST Figures Guide](https://mystmd.org/guide/figures).

### Building Outputs

One of the features we like best about MyST is that it targets exporting your content as a website as a first-class citizen. MyST exposes your content with a shared API (if you're reading more, look for "content server") and a separate program (look for "theme server") renders that content to a website. Out of the box, it currently ships a Remix app, so you can build either a Remix app or static HTML:
- **`myst start`**: Runs the MyST app with hot reloading during development.
- **`myst build --html`**: Exports to static HTML without the Remix app. See [MyST deployment docs](https://mystmd.org/guide/deployment#creating-static-html) for details.

```bash
# HTML preview
myst build --html

# PDF export (requires Typst)
myst build --all
```

### Deployment

The `.github/workflows/deploy.yml` workflow automatically builds and deploys to GitHub Pages on push to `main`.
