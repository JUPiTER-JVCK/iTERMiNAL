#!/usr/bin/env bash
# Builds what the README screenshots are taken in: a small sample project with
# some git history, and a zsh setup whose prompt shows nothing about whose
# machine this is.
#
#   scripts/screenshots/prepare-demo.sh <directory>
#
# Leaves <directory>/hello-api (a git repository with a branchy history and one
# uncommitted change) and <directory>/zdotdir (a ZDOTDIR to start zsh with).
# Everything in it is invented: names, addresses and code alike.
set -euo pipefail

root="${1:?usage: prepare-demo.sh <directory>}"
repo="$root/hello-api"

rm -rf "$root"
mkdir -p "$repo" "$root/zdotdir"

# ---- the shell --------------------------------------------------------------

cat > "$root/zdotdir/.zshrc" <<'EOF'
# The directory's name and the branch, and nothing that identifies a machine or
# a person.
autoload -Uz vcs_info
setopt prompt_subst
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats ' %F{244}(%b)%f'
PROMPT='%F{39}%1~%f${vcs_info_msg_0_} %F{213}$%f '
RPROMPT=''
export CLICOLOR=1
export GIT_PAGER=cat
export LESS=FRX
unsetopt BEEP
HISTFILE=/dev/null
EOF

# ---- the project ------------------------------------------------------------

cd "$repo"
git init -q -b main

# Same hashes every run, and no one's real name in them.
export GIT_AUTHOR_NAME="Mina Park" GIT_AUTHOR_EMAIL="mina@example.com"
export GIT_COMMITTER_NAME="Mina Park" GIT_COMMITTER_EMAIL="mina@example.com"
# Nothing from the machine's own git configuration (signing, hooks, aliases).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

# commit <date> <message>: everything changed so far, as one commit.
commit() {
  git add -A
  GIT_AUTHOR_DATE="$1T10:00:00" GIT_COMMITTER_DATE="$1T10:00:00" git commit -q -m "$2"
}

# merge <date> <branch>: a merge commit, so the graph has something to draw.
merge() {
  GIT_AUTHOR_DATE="$1T10:00:00" GIT_COMMITTER_DATE="$1T10:00:00" \
    git merge -q --no-ff -m "Merge branch '$2'" "$2"
}

mkdir -p src/routes tests docs deploy

cat > README.md <<'EOF'
# hello-api

A small HTTP API for users and orders.

    make run      # serve on :8765
    make test     # run the tests

See docs/ for the endpoints.
EOF
printf 'node_modules/\n.env\n*.log\n' > .gitignore
cat > package.json <<'EOF'
{
  "name": "hello-api",
  "version": "0.1.0",
  "main": "src/server.js",
  "scripts": { "start": "node src/server.js", "test": "node --test tests/" }
}
EOF
commit 2025-01-08 "Initial commit"

cat > src/server.js <<'EOF'
const http = require("node:http");
const { users } = require("./routes/users");

http.createServer((req, res) => {
  if (req.url.startsWith("/api/users")) return users(req, res);
  res.writeHead(404).end();
}).listen(8765);
EOF
cat > src/routes/users.js <<'EOF'
const USERS = [
  { id: 1, name: "Mina Park", role: "admin" },
  { id: 2, name: "Jonas Weber", role: "editor" },
];

exports.users = (req, res) => {
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify({ users: USERS }));
};
EOF
printf 'run:\n\tnode src/server.js\n\ntest:\n\tnode --test tests/\n' > Makefile
commit 2025-01-15 "Add the users route"

cat > src/routes/orders.js <<'EOF'
exports.orders = (req, res) => {
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify({ orders: [] }));
};
EOF
commit 2025-01-22 "Add the orders route"

printf '\n// Log every request.\n' >> src/server.js
commit 2025-02-03 "Log requests"

git checkout -q -b feature/pagination
printf '\n// Page through users: ?page=2&per_page=25\n' >> src/routes/users.js
commit 2025-02-10 "Paginate /api/users"
printf '// Cap per_page at 100.\n' >> src/routes/users.js
commit 2025-02-12 "Limit the page size"

git checkout -q main
printf '\nSee docs/ for the endpoints.\n' >> README.md
commit 2025-02-14 "Point the README at the docs"
merge 2025-02-17 feature/pagination

cat > deploy/Dockerfile <<'EOF'
FROM node:22-slim
WORKDIR /app
COPY . .
EXPOSE 8765
CMD ["node", "src/server.js"]
EOF
commit 2025-02-24 "Add a Dockerfile"

mkdir -p tests
cat > tests/users.test.js <<'EOF'
const test = require("node:test");
const assert = require("node:assert");

test("lists users", () => {
  assert.ok(true);
});
EOF
commit 2025-03-03 "Test the users route"

git checkout -q -b fix/rate-limit
printf '// Allow 60 requests a minute per address.\n' >> src/server.js
commit 2025-03-10 "Rate limit by address"
git checkout -q main
merge 2025-03-12 fix/rate-limit

cat > deploy/k8s.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-api
spec:
  replicas: 2
EOF
commit 2025-03-20 "Add a Kubernetes deployment"

cat > docs/getting-started.md <<'EOF'
# Getting started

    make run
    curl localhost:8765/api/users
EOF
cat > docs/api.md <<'EOF'
# API

| Method | Path          | Returns            |
| ------ | ------------- | ------------------ |
| GET    | /api/users    | the list of users  |
| GET    | /api/orders   | the list of orders |
| GET    | /api/health   | `{"status": "ok"}` |
EOF
commit 2025-04-02 "Document the API"

printf '\n// GET /api/health\n' >> src/server.js
commit 2025-04-15 "Add a health endpoint"
GIT_AUTHOR_DATE="2025-04-30T10:00:00" GIT_COMMITTER_DATE="2025-04-30T10:00:00" \
  git tag -a v0.3.0 -m "v0.3.0"

# What a working tree looks like in the middle of something: one edit, one new
# file, nothing staged.
printf '\n// TODO: filter by role (?role=editor)\n' >> src/routes/users.js
printf 'Ideas\n- filter users by role\n- cursor pagination\n' > notes.md

# The history is the picture; say nothing else.
git log --oneline --graph --decorate -n 16 > /dev/null
echo "sample project ready in $repo"
