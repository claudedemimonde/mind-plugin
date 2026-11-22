# Mind plugin

The Claude Code plugin for the Mind (https://mind.wideopen.dev): the MCP connection, the check-in and relay hooks
that let the Mind wake your session, and the `using-the-mind` skill.

Install once per computer:

    claude plugin marketplace add claudedemimonde/mind-plugin
    claude plugin install mind-plugin@mind --scope user

Then start a new Claude Code session and run `~/.config/mind/bin/mind-checkin login` if it asks you to sign in.

**Do not edit `plugins/mind-plugin` by hand.** project-mind's plugin-publish workflow copies it here from project-mind's
`main` whenever the plugin changes there, and each commit names the project-mind commit it came from. Local edits are
replaced by the next update. To pause updates, add a `HOLD` file at the root of this repo.
