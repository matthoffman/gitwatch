#!/usr/bin/env bash
#
# gitwatch - watch file or directory and git commit all changes as they happen
#
# Copyright (C) 2013  Patrick Lehner
#   with modifications and contributions by:
#   - Matthew McGowan
#   - Dominik D. Geyer
#
#############################################################################
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#############################################################################
#
#   Idea and original code taken from http://stackoverflow.com/a/965274
#       (but heavily modified by now)
#
#   Requires the command 'inotifywait' to be available, which is part of
#   the inotify-tools (See https://github.com/rvoicilas/inotify-tools ),
#   and (obviously) git.
#   Will check the availability of both commands using the `which` command
#   and will abort if either command (or `which`) is not found.
#
set -euo pipefail

REMOTE=""
BRANCH="master"
SLEEP_TIME=8
DATE_FMT="+%Y-%m-%d %H:%M:%S"
COMMITMSG="Gitwatch: auto-commit on change (%d)"
GIT_DIR=""
ENABLE_PULL="false"

shelp () { # Print a message about how to use this script
    echo "gitwatch - watch file or directory and git commit all changes as they happen"
    echo ""
    echo "Usage:"
    echo "${0} [-s <secs>] [-d <fmt>] [-r <remote> [-b <branch>]]"
    echo "         [-g <git-dir>] [-p] [-m <msg>] <target>"
    echo ""
    echo "Where <target> is the file or folder which should be watched. The target needs"
    echo "to be in a Git repository, or in the case of a folder, it may also be the top"
    echo "folder of the repo."
    echo ""
    echo " -s <secs>        after detecting a change to the watched file or directory,"
    echo "                  wait <secs> seconds until committing, to allow for more"
    echo "                  write actions of the same batch to finish; default is 2sec"
    echo " -d <fmt>         the format string used for the timestamp in the commit"
    echo "                  message; see 'man date' for details; default is "
    echo "                  \"+%Y-%m-%d %H:%M:%S\""
    echo " -r <remote>      if defined, a 'git push' to the given <remote> is done after"
    echo "                  every commit"
    echo " -b <branch>      the branch which should be pushed automatically;"
    echo "                - if not given, the push command used is  'git push <remote>',"
    echo "                    thus doing a default push (see git man pages for details)"
    echo "                - if given and"
    echo "                  + repo is in a detached HEAD state (at launch)"
    echo "                    then the command used is  'git push <remote> <branch>'"
    echo "                  + repo is NOT in a detached HEAD state (at launch)"
    echo "                    then the command used is"
    echo "                    'git push <remote> <current branch>:<branch>'  where"
    echo "                    <current branch> is the target of HEAD (at launch)"
    echo "                  if no remote was define with -r, this option has no effect"
    echo " -m <msg>         the commit message used for each commit; all occurrences of"
    echo "                  %d in the string will be replaced by the formatted date/time"
    echo "                  (unless the <fmt> specified by -d is empty, in which case %d"
    echo "                  is replaced by an empty string); the default message is:"
    echo "                  \"Gitwatch: auto-commit on change (%d)\""
    echo " -g <git-dir>     Git directory (Equals to <target>/.git if not specified)"
    echo " -P               Enable pull before push"
    echo ""
    echo "As indicated, several conditions are only checked once at launch of the"
    echo "script. You can make changes to the repo state and configurations even while"
    echo "the script is running, but that may lead to undefined and unpredictable (even"
    echo "destructive) behavior!"
    echo "It is therefore recommended to terminate the script before changing the repo's"
    echo "configuration and restarting it afterwards."
    echo ""
    echo "By default, gitwatch tries to use the binaries \"git\" and \"inotifywait\" (on"
    echo "Linux) or \"fswatch\" (on OS X), expecting to find them in the PATH (it uses"
    echo "'which' to check this and will abort with an error if they cannot be found). "
    echo "If you want to use binaries that are named differently and/or located outside "
    echo "of your PATH, you can define replacements in the environment variables"
    echo "GW_GIT_BIN and GW_INW_BIN for git and inotifywait/fswatch, respectively."
}

stderr () {
    echo "$1" >&2
}

while getopts b:d:hPm:p:r:s:g: option # Process command line options
do
    case "${option}" in
        b) BRANCH=${OPTARG};;
        d) DATE_FMT=${OPTARG};;
        P) ENABLE_PULL="true";;
        h) shelp; exit;;
        m) COMMITMSG=${OPTARG};;
        p|r) REMOTE=${OPTARG};;
        s) SLEEP_TIME=${OPTARG};;
        g) GIT_DIR=${OPTARG};;
        *) shelp; exit 1;
    esac
done

shift $((OPTIND-1)) # Shift the input arguments, so that the input file (last arg) is $1 in the code below

if [ $# -ne 1 ]; then # If no command line arguments are left (that's bad: no target was passed)
    stderr "No directory argument present"
    shelp # print usage help
    exit # and exit
fi

is_command () { # Tests for the availability of a command
	which "$1" &>/dev/null
}

# if custom bin names are given for git or inotifywait, use those; otherwise fall back to "git" and "inotifywait"
if [[ -z "${GW_GIT_BIN:-}" ]]; then GIT="git"; else GIT="$GW_GIT_BIN"; fi
if [[ -z "${GW_INW_BIN:-}" ]]; then INW="inotifywait"; else INW="$GW_INW_BIN"; fi
if [[ -z "${GW_RL_BIN:-}" ]]; then RL="readlink"; else INW="$GW_RL_BIN"; fi

# if Mac, use fswatch
if [ "$(uname)" == "Darwin" ]; then
  INW="fswatch"
  RL="greadlink"
fi

# Check availability of selected binaries and die if not met
for cmd in "$GIT" "$INW" "$RL"; do
	is_command "$cmd" || { stderr "Error: Required command '$cmd' not found." ; exit 1; }
done
unset cmd

# Expand the path to the target to absolute path
IN=$($RL -f "$1")


if [ -d "$1" ]; then # if the target is a directory
    TARGETDIR=$(sed -e "s/\/*$//" <<<"$IN") # dir to CD into before using git commands: trim trailing slash, if any
    INCOMMAND="$INW --exclude=\"^${TARGETDIR}/\.git\" -qqr -e close_write,move,delete,create $TARGETDIR" # construct inotifywait-commandline
    # Mac/fswatch only supports watching paths
    if [ "$(uname)" == "Darwin" ]; then
      INCOMMAND="$INW -1 -r -x --exclude .DS_Store --exclude .git --event Created --event Removed --event MovedTo --event MovedFrom --event Renamed --event Updated $TARGETDIR"
    fi
    GIT_ADD_ARGS="." # add "." (CWD) recursively to index
    GIT_COMMIT_ARGS="-a" # add -a switch to "commit" call just to be sure
elif [ -f "$1" ]; then # if the target is a single file
    if [ "$(uname)" == "Darwin" ]; then
        echo "gitwatch only supports watching directories on OS X"
        exit 1
    fi

    TARGETDIR=$(dirname "$IN") # dir to CD into before using git commands: extract from file name
    INCOMMAND="$INW -qq -e close_write,move,delete $IN" # construct inotifywait-commandline
    GIT_ADD_ARGS="$IN" # add only the selected file to index
    GIT_COMMIT_ARGS="" # no need to add anything more to "commit" call
else
    stderr "Error: The target is neither a regular file nor a directory."
    exit 1
fi

if [ -z "$GIT_DIR" ]; then GIT_DIR="$TARGETDIR/.git"; fi
if [ ! -d "$GIT_DIR" ]; then echo "$GIT_DIR is not a directory"; exit 1; fi

# Check if commit message needs any formatting (date splicing)
if ! grep "%d" > /dev/null <<< "$COMMITMSG"; then # if commitmsg didnt contain %d, grep returns non-zero
    DATE_FMT="" # empty date format (will disable splicing in the main loop)
    FORMATTED_COMMITMSG="$COMMITMSG" # save (unchanging) commit message
fi

cd "$TARGETDIR" # CD into right dir

if [ -n "$REMOTE" ]; then # are we pushing to a remote?
    if [ -z "$BRANCH" ]; then # Do we have a branch set to push to ?
        PUSH_CMD="$GIT push $REMOTE" # Branch not set, push to remote without a branch
    else
        # check if we are on a detached HEAD
        if HEADREF=$(git symbolic-ref HEAD 2> /dev/null); then # HEAD is not detached
            PUSH_CMD="$GIT push $REMOTE $(sed "s_^refs/heads/__" <<< "$HEADREF"):$BRANCH"
        else # HEAD is detached
            PUSH_CMD="$GIT push $REMOTE $BRANCH"
        fi
    fi
else
    PUSH_CMD="" # if not remote is selected, make sure push command is empty
fi

# main program loop: wait for changes and commit them
while true; do
    $ENABLE_PULL && $GIT pull -X theirs # initial pull to get current state
    $INCOMMAND # wait for changes
    sleep "$SLEEP_TIME" # wait some more seconds to give apps time to write out all changes
    if [ -n "$DATE_FMT" ]; then
        FORMATTED_COMMITMSG="$(sed "s/%d/$(date "$DATE_FMT")/" <<< "$COMMITMSG")" # splice the formatted date-time into the commit message
    fi
    cd "$TARGETDIR" # CD into right dir
    # Get changed files count
    CHANGED=$($GIT --work-tree "$TARGETDIR" --git-dir "$GIT_DIR" status --short | wc -l)
    if [ "x$CHANGED" != "x0" ]; then # commit only if changed files still exist
        $GIT --work-tree "$TARGETDIR" --git-dir "$GIT_DIR" add "$GIT_ADD_ARGS" # add file(s) to index
        $GIT --work-tree "$TARGETDIR" --git-dir "$GIT_DIR" commit "$GIT_COMMIT_ARGS" -m"$FORMATTED_COMMITMSG" # construct commit message and commit
    fi

    if [ -n "$PUSH_CMD" ]; then
        if $ENABLE_PULL; then
            $GIT fetch "$REMOTE"
            timestamp=$(date +'%Y-%m-%dT%H:%M:%S%z');
            for file in $(git diff --name-only --diff-filter=U); do
                $GIT show ":1:${file}" > "${file}.${timestamp}".original
                $GIT show ":2:${file}" > "${file}.${timestamp}".yours
                $GIT show ":3:${file}" > "${file}.${timestamp}".theirs
            done
        fi
        $PUSH_CMD;
    fi
done
