# Runs the Morning Dew backend (server/server.js) on any host that can run a
# Docker container — used by render.yaml for the free Render deploy described
# in README.md "Deploying the backend". Bun serves the frontend files in this
# same directory and proxies calendar/reminders/email; see server/server.js.
FROM oven/bun:1

WORKDIR /app
COPY . .

# Render (and most container hosts) inject PORT at runtime; server.js already
# reads process.env.PORT, falling back to 8787 for local/non-Render use.
EXPOSE 8787

CMD ["bun", "run", "server/server.js"]
