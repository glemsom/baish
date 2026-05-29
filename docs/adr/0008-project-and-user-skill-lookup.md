# Project and user skill lookup

BAISH V1 will load explicit `/skill:<skill>` requests from project-local skills first and user-global skills second, using paths such as `./.baish/skills/<skill>.md` and `~/.baish/skills/<skill>.md`. This supports repository-specific workflows while still letting developers keep reusable personal instruction bundles across projects.
