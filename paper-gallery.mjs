// inspired by FreekPols and luukfroling's gallery https://github.com/TUD-JB-Templates/JB2_plugins
import fs from 'fs/promises';
import { readFileSync } from 'fs';
import path from 'path';
import yaml from 'js-yaml';

// used for debugging locally
const LOCAL_PATH = process.env.NEXUS_LOCAL_PATH;

const GITHUB_RAW_BASE = 'https://raw.githubusercontent.com/pollomarzo';
const GITHUB_PAGES_BASE = 'https://pollomarzo.github.io';

function parsePapers() {
  const lines = readFileSync('papers.txt', 'utf8').split('\n');
  const papers = [];
  let currentYear = null;

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith('#')) {
      currentYear = trimmed.slice(1).trim();
    } else {
      papers.push({ name: trimmed, year: currentYear });
    }
  }
  return papers;
}

async function fetchPaperConfig(name) {
  if (LOCAL_PATH) {
    const configPath = path.join(LOCAL_PATH, name, 'myst.yml');
    const content = await fs.readFile(configPath, 'utf8');
    return yaml.load(content);
  } else {
    const url = `${GITHUB_RAW_BASE}/${name}/main/myst.yml`;
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Failed to fetch config for "${name}": ${response.status} ${response.statusText}`);
    }
    return yaml.load(await response.text());
  }
}

const paperCardsDirective = {
  name: 'paper-cards',
  doc: 'Generate a gallery of paper cards',
  options: {
    subset: { type: String, doc: 'Filter by year' },
  },
  run(data) {
    const subset = data.options?.subset;
    const papers = parsePapers().filter(p => !subset || p.year === subset);
    console.log(`paper-cards: subset=${subset}, found ${papers.length} papers`);

    if (papers.length === 0) {
      return [{ type: 'paragraph', children: [{ type: 'text', value: 'No papers found.' }] }];
    }

    return [
      {
        type: 'grid',
        columns: [1, 1, 2, 3],
        children: papers.map(({ name }) => ({ type: 'paper-card-ref', name, children: [] })),
      },
    ];
  },
};

function paperCardsTransform(opts, utils) {
  return async (mdast) => {
    const nodes = utils.selectAll('paper-card-ref', mdast);
    if (nodes.length === 0) return;

    await Promise.all(
      nodes.map(async (node) => {
        const config = await fetchPaperConfig(node.name);
        console.log(`Building card for "${node.name}"`);

        const title = config.project.title || node.name;
        const keywords = config.project.keywords || [];

        // Mutate node into a card
        node.type = 'card';
        node.url = `${GITHUB_PAGES_BASE}/${node.name}`;
        node.children = [
          { type: 'header', children: [{ type: 'text', value: title }] },
          {
            type: 'image',
            url: `${GITHUB_RAW_BASE}/${node.name}/main/thumbnails/thumbnail.png`,
            alt: title,
            width: '100%',
          },
        ];

        if (keywords.length > 0) {
          node.children.push({
            type: 'paragraph',
            children: [{ type: 'text', value: keywords.join(' | ') }],
          });
        }
      })
    );
  };
}

const plugin = {
  name: 'Paper Gallery',
  directives: [paperCardsDirective],
  transforms: [{ plugin: paperCardsTransform, stage: 'document' }],
};

export default plugin;
