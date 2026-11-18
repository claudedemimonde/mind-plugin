# Mind plugin

The Claude Code plugin for the Mind (https://mind.wideopen.dev): the MCP connection, the check-in and relay hooks
that let the Mind wake your session, and the `using-the-mind` skill.

Install once per computer:

    claude plugin marketplace add claudedemimonde/mind-plugin
    claude plugin install mind-plugin@mind --scope user

Then start a new Claude Code session and run `~/.config/mind/bin/mind-checkin login` if it asks you to sign in.

**Do not edit this repo by hand.** The Mind copies `plugins/mind-plugin` here from project-mind; each update is a pull
request the Mind merges. Local edits are replaced by the next update. Copied from project-mind 04c7c79.
