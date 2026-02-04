---
title: Conda/Mamba Tutorial
description: Getting started with conda and mamba for environment management
---

The only requirement to follow our instructions is having conda or mamba installed. Getting there is easier than it sounds!

**What even are these things?**

Think of conda as a tool that installs other tools. When you need a Python library (or Python itself), conda fetches it, installs it, and makes sure everything plays nicely together. Mamba does the exact same thing, just faster. You'll get both.

**Why does this feel complicated?**

There are many options with confusing names. You might have heard of Anaconda, Miniconda, Mambaforge, Miniforge... they all do roughly the same thing. We're going to ignore all of that and just install **Miniforge**, which is free, lightweight, and gives you everything you need.


## Installation

**Go to [conda-forge.org/download](https://conda-forge.org/download/)** and download the installer for your system.

### Windows

1. Run the downloaded `.exe` file
2. Choose "Just Me" when asked
3. **Important:** Check the box that says "Add Miniforge3 to my PATH" — this lets you use conda from any terminal
4. Finish the installation

### macOS

1. Run the downloaded `.pkg` file  
2. Follow the prompts, accepting defaults
3. When it finishes, open Terminal and you're ready

### Linux

```bash
bash Miniforge3-Linux-x86_64.sh
```

Accept the license, confirm the install location, and say "yes" when it asks to initialize.

## Verify it worked

Open a fresh terminal (or command prompt on Windows—you may need to use "Miniforge Prompt" from the Start menu) and type:

```bash
mamba --version
```

If you see a version number, you're done! 🎉

## Wait, what's an "environment"?

You'll see us (and others) talk about "environments." Think of them as separate workspaces. If one project needs specific versions of tools that might conflict with another project, environments keep them isolated. You don't need to understand this deeply right now—just know that when we say `mamba create -n myproject`, we're making a fresh workspace called "myproject," and `mamba activate myproject` switches you into it.


**Something went wrong?** The most common issue is that your terminal can't find conda. Try closing and reopening your terminal. On Windows, try searching for "Miniforge Prompt" in the Start menu and using that instead.
