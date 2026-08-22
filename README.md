# skills

Reusable [Copilot skills](https://docs.github.com/copilot). Each directory holds
one skill: a `SKILL.md` with frontmatter that tells the agent when to load it,
plus any reference implementation the skill refers to.

## Skills

| Skill | What it does |
|---|---|
| [`azure-python-deploy`](azure-python-deploy/) | Deploy a Python web app (Streamlit, Flask, FastAPI, Gradio) to Azure App Service so it is publicly reachable over HTTPS. |

## Installing

Copy a skill directory into your personal skills directory:

```bash
git clone https://github.com/nkamkheaw/skills.git
cp -r skills/azure-python-deploy ~/.copilot/skills/
```

The agent discovers it automatically from the `description` in the frontmatter —
there is nothing to register.

## What these are written to be

Each skill documents a procedure that was **actually run end to end**, not one
assembled from documentation. That distinction matters: several of the most
useful notes in `azure-python-deploy` are failures that every command reported as
a success, which is exactly the kind of thing official docs do not tell you.

Timing figures are measured rather than estimated, and are labelled with the
conditions they were measured under, because some of them (upload speed in
particular) will not transfer to another machine or connection.
