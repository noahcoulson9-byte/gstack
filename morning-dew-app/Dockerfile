# Runs the Morning Dew backend (server/server.js) on any host that can run a
# Docker container — used by render.yaml for the free Render deploy described
# in README.md "Deploying the backend". Bun serves the frontend files in this
# same directory and proxies calendar/reminders/email; see server/server.js.
# Pinned (not the floating :1 tag): every Render rebuild used to pull whatever
# Bun had shipped that week, so a runtime regression could silently break the
# backend with zero code changes. Bump this deliberately, after testing.
FROM oven/bun:1.2

WORKDIR /app
COPY . .

# Install backend deps (web-push for the morning notification). Bun reads
# package.json; this is a no-op for the frontend, which ships no dependencies.
RUN bun install

# Render (and most container hosts) inject PORT at runtime; server.js already
# reads process.env.PORT, falling back to 8787 for local/non-Render use.
EXPOSE 8787

CMD ["bun", "run", "server/server.js"]
