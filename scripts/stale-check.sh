#!/bin/bash
# Check for stale uncommitted/untracked files and remind team
cd /home/xertrov/src/c2c

# Uncommitted changes (staged or unstaged)
uncommitted=$(git status --porcelain | grep -v "^??" | wc -l)

# Untracked files older than 30 minutes
old_untracked=$(find . -maxdepth 3 -type f -newer ~/.gitindex 2>/dev/null | grep -v "^./\.git" | grep -v "^./_build" | grep -v "^./node_modules" | head -10)

# Check last commit time (if no commits in 30+ min, remind team)
last_commit_age=$(git log -1 --format='%ct' 2>/dev/null)
now=$(date +%s)
if [ -n "$last_commit_age" ]; then
    age_minutes=$(( (now - last_commit_age) / 60 ))
    if [ $age_minutes -gt 30 ] && [ "$uncommitted" -eq 0 ]; then
        echo "STALE: No commits in ${age_minutes}m. Team should commit regularly."
    fi
fi

if [ "$uncommitted" -gt 0 ]; then
    echo "UNCOMMITTED: $uncommitted file(s) with uncommitted changes"
    git status --short | head -20
fi

if [ -n "$old_untracked" ]; then
    echo "OLD UNTRACKED:"
    echo "$old_untracked"
fi
