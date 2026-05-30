# Project and user skill lookup

BAISH V1 will load explicit `/skill:<skill>` requests from project-local skills first and user-global skills second, using paths such as `./.baish/skills/<skill>/SKILL.md` and `~/.baish/skills/<skill>/SKILL.md`. This supports repository-specific workflows while still letting developers keep reusable personal instruction bundles across projects. Using a folder per skill also allows skills to reference additional files (e.g. scripts, reference docs) stored alongside or inside the skill directory.
