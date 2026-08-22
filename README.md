# skills

Reusable agent skills. Each directory holds one skill: a `SKILL.md` with
frontmatter that tells the agent when to load it, plus any reference
implementation the skill refers to.

The format is deliberately plain — Markdown with a small YAML frontmatter block,
and shell scripts alongside it. Nothing here is tied to a particular assistant or
tool, so a skill can be dropped into any harness that reads skill files, pasted
in as context, or simply read by a human.

## Skills

| Skill | What it does |
|---|---|
| [`azure-python-deploy`](azure-python-deploy/) | Deploy a Python web app (Streamlit, Flask, FastAPI, Gradio) to Azure App Service so it is publicly reachable over HTTPS. |

## Installing

Clone the repository and copy the skill directory into wherever your agent looks
for skills:

```bash
git clone https://github.com/nkamkheaw/skills.git
cp -r skills/azure-python-deploy <your-skills-directory>/
```

Most harnesses load skills from a directory of their own and pick them up from
the `description` in the frontmatter, so there is usually nothing to register. If
yours has no skill mechanism at all, `SKILL.md` still works read as a runbook or
handed to the model as context.

## What these are written to be

Each skill documents a procedure that was **actually run end to end**, not one
assembled from documentation. That distinction matters: several of the most
useful notes in `azure-python-deploy` are failures that every command reported as
a success, which is exactly the kind of thing official docs do not tell you.

Timing figures are measured rather than estimated, and are labelled with the
conditions they were measured under, because some of them (upload speed in
particular) will not transfer to another machine or connection.
