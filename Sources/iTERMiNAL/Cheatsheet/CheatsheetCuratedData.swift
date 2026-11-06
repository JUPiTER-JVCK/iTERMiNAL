import Foundation

extension CheatsheetCurated {
    // swiftlint:disable line_length
    static let text = #"""
    # --- git -----------------------------------------------------------------
    prog git | Distributed version control
    use git <command> [<args>]
    use git -C <path> <command>
    tags vcs source-control repository github

    sec Start
    ? Create a repository in the current folder
    $ git init
    ~ new repo initialise
    ? Clone a repository
    $ git clone {{url}}
    ~ download checkout copy
    ? Clone only the latest snapshot, without the history
    $ git clone --depth 1 {{url}}
    ~ shallow fast small

    sec Status and staging
    ? Show what has changed
    $ git status
    ? Show changes that are not staged yet
    $ git diff
    ~ what changed unstaged
    ? Show changes that are staged for the next commit
    $ git diff --staged
    ~ cached index
    ? Stage a file
    $ git add {{file}}
    ~ track include
    ? Stage everything, including deletions
    $ git add -A
    ~ all
    ? Choose which hunks to stage
    $ git add -p
    ~ patch interactive partial

    sec Commit
    ? Commit what is staged
    $ git commit -m "{{message}}"
    ~ save record
    ? Stage every tracked file that changed and commit
    $ git commit -am "{{message}}"
    ? Change the message of the last commit
    $ git commit --amend
    ~ edit fix rewrite
    ? Add staged changes to the last commit, keeping its message
    $ git commit --amend --no-edit
    ~ forgot missed file

    sec Branches
    ? List branches
    $ git branch
    ? List local and remote branches
    $ git branch -a
    ? Create a branch and switch to it
    $ git switch -c {{branch}}
    ~ new checkout
    ? Switch to a branch
    $ git switch {{branch}}
    ~ checkout change
    ? Rename the current branch
    $ git branch -m {{new_name}}
    ~ move
    ? Delete a branch that has been merged
    $ git branch -d {{branch}}
    ~ remove
    ? Delete a branch even if it has not been merged
    $ git branch -D {{branch}}
    ~ remove force

    sec Remotes
    ? List the remotes and their URLs
    $ git remote -v
    ? Download everything from the remotes, and forget deleted branches
    $ git fetch --all --prune
    ~ update
    ? Pull and rebase your commits on top
    $ git pull --rebase
    ~ update sync
    ? Push a new branch and remember where it goes
    $ git push -u origin {{branch}}
    ~ publish upload upstream
    ? Force-push, but not over work you have not seen
    $ git push --force-with-lease
    ~ overwrite safe
    ? Delete a branch on the remote
    $ git push origin --delete {{branch}}
    ~ remove

    sec Undo
    ? Undo the last commit, keeping its changes staged
    $ git reset --soft HEAD~1
    ~ uncommit rollback revert
    ? Undo the last commit and throw its changes away
    $ git reset --hard HEAD~1
    ~ uncommit discard delete destroy
    ? Discard the changes to a file
    $ git restore {{file}}
    ~ undo revert checkout
    ? Unstage a file, keeping its changes
    $ git restore --staged {{file}}
    ~ undo reset remove
    ? Make a new commit that undoes an earlier one
    $ git revert {{commit}}
    ~ undo rollback
    ? Take a file back as it was in an earlier commit
    $ git restore --source {{commit}} {{file}}
    ~ checkout old version
    ? Delete untracked files and folders
    $ git clean -fd
    ~ remove untracked cleanup
    ? Show where HEAD has been, to find a lost commit
    $ git reflog
    ~ recover lost history

    sec History
    ? Show the history, one line per commit
    $ git log --oneline
    ~ short compact
    ? Show the history as a graph of branches
    $ git log --oneline --graph --decorate --all
    ~ tree visual
    ? Show the history of one file, with the changes
    $ git log -p {{file}}
    ? Show who last changed each line of a file
    $ git blame {{file}}
    ~ author
    ? Show one commit
    $ git show {{commit}}
    ? Find commits that added or removed some text
    $ git log -S "{{text}}"
    ~ search pickaxe
    ? Find the commit that introduced a bug
    $ git bisect start
    ~ binary search broke

    sec Merge and rebase
    ? Merge a branch into the current one
    $ git merge {{branch}}
    ? Replay your commits on top of another branch
    $ git rebase {{branch}}
    ? Rewrite the last few commits
    $ git rebase -i HEAD~{{3}}
    ~ squash reorder edit interactive
    ? Apply one commit from another branch
    $ git cherry-pick {{commit}}
    ~ copy pick
    ? Give up on a merge in progress
    $ git merge --abort
    ~ cancel stop undo

    sec Stash
    ? Set uncommitted changes aside
    $ git stash
    ~ shelve save temporarily
    ? Bring back the stashed changes
    $ git stash pop
    ~ restore apply
    ? List the stashes
    $ git stash list

    sec Tags and settings
    ? Tag the current commit
    $ git tag {{name}}
    ~ release version
    ? Push the tags to the remote
    $ git push --tags
    ? Set the name used in your commits
    $ git config --global user.name "{{name}}"
    ~ author identity

    # --- ls ------------------------------------------------------------------
    prog ls | List the files in a folder
    use ls [options] [file ...]
    tags list dir directory
    ? List all files, including hidden ones, with details
    $ ls -la
    ~ show everything dotfiles
    ? List with sizes in KB, MB or GB
    $ ls -lh
    ~ human readable size
    ? List the newest files first
    $ ls -lt
    ~ recent modified sort by date
    ? List the oldest files first
    $ ls -ltr
    ~ sort by date reverse
    ? List the biggest files first
    $ ls -lhS
    ~ largest size sort
    ? List only the folders
    $ ls -d */
    ~ directories
    ? List a folder and everything under it
    $ ls -R {{folder}}
    ~ recursive tree
    ? List one name per line
    $ ls -1
    ? List with colours
    $ ls -G
    ~ colour color

    # --- cp ------------------------------------------------------------------
    prog cp | Copy files and folders
    use cp [options] source target
    use cp [options] source ... directory
    tags copy duplicate
    ? Copy a file
    $ cp {{source}} {{target}}
    ? Copy a folder and everything in it
    $ cp -R {{folder}} {{target}}
    ~ recursive directory
    ? Copy a file into a folder
    $ cp {{file}} {{folder}}/
    ? Ask before overwriting
    $ cp -i {{source}} {{target}}
    ~ prompt confirm
    ? Never overwrite an existing file
    $ cp -n {{source}} {{target}}
    ~ no clobber keep
    ? Copy and keep the dates and permissions
    $ cp -p {{source}} {{target}}
    ~ preserve timestamps metadata
    ? Copy instantly with APFS cloning, using no extra space
    $ cp -c {{source}} {{target}}
    ~ clone copy on write fast
    ? Copy several files into a folder
    $ cp {{file1}} {{file2}} {{folder}}/

    # --- mv ------------------------------------------------------------------
    prog mv | Move or rename files and folders
    use mv [options] source target
    use mv [options] source ... directory
    tags move rename
    ? Rename a file or folder
    $ mv {{old_name}} {{new_name}}
    ~ change name
    ? Move a file into a folder
    $ mv {{file}} {{folder}}/
    ? Move several files into a folder
    $ mv {{file1}} {{file2}} {{folder}}/
    ? Ask before overwriting
    $ mv -i {{source}} {{target}}
    ~ prompt confirm
    ? Never overwrite an existing file
    $ mv -n {{source}} {{target}}
    ~ no clobber keep
    ? Say what was moved
    $ mv -v {{source}} {{target}}
    ~ verbose

    # --- rm ------------------------------------------------------------------
    prog rm | Delete files and folders
    use rm [options] file ...
    tags delete remove erase
    ? Delete a file
    $ rm {{file}}
    ~ remove erase
    ? Delete a folder and everything in it
    $ rm -r {{folder}}
    ~ remove directory recursive
    ? Delete a folder without asking, whatever is in it
    $ rm -rf {{folder}}
    ~ force remove directory recursive
    ? Ask before deleting each file
    $ rm -i {{file}}
    ~ prompt confirm
    ? Delete an empty folder
    $ rm -d {{folder}}
    ~ rmdir remove directory
    ? Say what was deleted
    $ rm -v {{file}}
    ~ verbose
    ? Move a file to the Trash instead of deleting it
    $ osascript -e 'tell application "Finder" to delete POSIX file "{{path}}"'
    ~ recycle bin undo safe

    # --- mkdir ---------------------------------------------------------------
    prog mkdir | Make folders
    use mkdir [options] directory ...
    tags make create directory folder
    ? Create a folder
    $ mkdir {{folder}}
    ~ new directory
    ? Create a folder and any parents that are missing
    $ mkdir -p {{path/to/folder}}
    ~ nested deep parents
    ? Create several folders at once
    $ mkdir -p {{project}}/{src,tests,docs}
    ~ multiple tree structure
    ? Create a folder with set permissions
    $ mkdir -m 700 {{folder}}
    ~ mode private
    ? Say what was created
    $ mkdir -v {{folder}}
    ~ verbose

    # --- ln ------------------------------------------------------------------
    prog ln | Make links between files
    use ln [options] target link
    tags link symlink shortcut alias
    ? Make a symbolic link
    $ ln -s {{target}} {{link}}
    ~ symlink shortcut alias
    ? Make a symbolic link, replacing one that exists
    $ ln -sf {{target}} {{link}}
    ~ overwrite update force
    ? Make a hard link
    $ ln {{target}} {{link}}
    ? Show where a symbolic link points
    $ readlink {{link}}
    ~ target resolve

    # --- cat -----------------------------------------------------------------
    prog cat | Print files
    use cat [options] [file ...]
    tags show print display concatenate
    ? Print a file
    $ cat {{file}}
    ~ show display contents read
    ? Print a file with line numbers
    $ cat -n {{file}}
    ~ number
    ? Join files into one
    $ cat {{file1}} {{file2}} > {{combined}}
    ~ merge concatenate combine
    ? Write what you type into a file, until Ctrl-D
    $ cat > {{file}}
    ~ create make new
    ? Show tabs and line ends
    $ cat -et {{file}}
    ~ invisible whitespace characters
    ? Squeeze runs of blank lines into one
    $ cat -s {{file}}

    # --- head ----------------------------------------------------------------
    prog head | Print the start of a file
    use head [-n lines | -c bytes] [file ...]
    tags first top beginning
    ? Print the first 10 lines
    $ head {{file}}
    ~ top beginning
    ? Print the first lines, as many as you say
    $ head -n {{20}} {{file}}
    ? Print the first bytes
    $ head -c {{100}} {{file}}
    ? Show only the first lines of a command's output
    $ {{command}} | head -n {{5}}
    ~ limit pipe

    # --- tail ----------------------------------------------------------------
    prog tail | Print the end of a file
    use tail [-F | -f | -r] [-n lines] [file ...]
    tags last end bottom log
    ? Print the last 10 lines
    $ tail {{file}}
    ~ end bottom
    ? Print the last lines, as many as you say
    $ tail -n {{20}} {{file}}
    ? Follow a file as it grows
    $ tail -f {{file}}
    ~ watch live log stream
    ? Follow a file, even if it is replaced or rotated
    $ tail -F {{file}}
    ~ log rotation
    ? Print a file from its second line on
    $ tail -n +2 {{file}}
    ~ skip header first line
    ? Print a file backwards, last line first
    $ tail -r {{file}}
    ~ reverse

    # --- wc ------------------------------------------------------------------
    prog wc | Count lines, words and bytes
    use wc [-clmw] [file ...]
    tags count length size
    ? Count the lines in a file
    $ wc -l {{file}}
    ~ number of lines
    ? Count the words in a file
    $ wc -w {{file}}
    ? Count the bytes in a file
    $ wc -c {{file}}
    ~ size
    ? Count the lines a command prints
    $ {{command}} | wc -l
    ~ how many results pipe
    ? Show lines, words and bytes together
    $ wc {{file}}

    # --- sort ----------------------------------------------------------------
    prog sort | Sort lines of text
    use sort [options] [file ...]
    tags order arrange
    ? Sort a file
    $ sort {{file}}
    ~ alphabetical order
    ? Sort backwards
    $ sort -r {{file}}
    ~ reverse descending
    ? Sort numbers by value
    $ sort -n {{file}}
    ~ numeric
    ? Sort sizes like 2K and 1G
    $ sort -h {{file}}
    ~ human readable numbers
    ? Sort and drop repeated lines
    $ sort -u {{file}}
    ~ unique duplicates remove
    ? Sort by the second column
    $ sort -k 2 {{file}}
    ~ field column key
    ? Sort a CSV by its third field
    $ sort -t, -k3 {{file.csv}}
    ~ delimiter comma separated
    ? Count how often each line appears, most common first
    $ sort {{file}} | uniq -c | sort -rn
    ~ frequency duplicates occurrences histogram

    # --- diff ----------------------------------------------------------------
    prog diff | Compare files and folders
    use diff [options] file1 file2
    tags compare difference changes
    ? Show how two files differ
    $ diff {{file1}} {{file2}}
    ~ compare changes
    ? Show the differences in the format patches use
    $ diff -u {{file1}} {{file2}}
    ~ unified patch
    ? Compare two folders
    $ diff -r {{folder1}} {{folder2}}
    ~ directories recursive
    ? Only say whether two files differ
    $ diff -q {{file1}} {{file2}}
    ~ same identical brief
    ? Show two files side by side
    $ diff -y {{file1}} {{file2}}
    ~ columns
    ? Ignore whitespace
    $ diff -w {{file1}} {{file2}}
    ~ spaces
    ? Compare the output of two commands
    $ diff <({{command1}}) <({{command2}})
    ~ process substitution

    # --- grep ----------------------------------------------------------------
    prog grep | Search text for a pattern
    use grep [options] pattern [file ...]
    tags search find text regex
    ? Find lines containing some text in a file
    $ grep "{{text}}" {{file}}
    ~ search match
    ? Search every file in a folder
    $ grep -r "{{text}}" {{folder}}
    ~ recursive find in files directory
    ? Search recursively and show line numbers
    $ grep -rn "{{text}}" {{folder}}
    ~ where location
    ? Search without caring about case
    $ grep -i "{{text}}" {{file}}
    ~ case insensitive
    ? Show the lines that do not match
    $ grep -v "{{text}}" {{file}}
    ~ exclude invert without
    ? Match whole words only
    $ grep -w "{{word}}" {{file}}
    ? Search for a regular expression with alternatives
    $ grep -E "{{one|two}}" {{file}}
    ~ regex extended or
    ? Search for text that looks like a pattern, literally
    $ grep -F "{{text}}" {{file}}
    ~ fixed string no regex
    ? Show lines around each match
    $ grep -C {{3}} "{{text}}" {{file}}
    ~ context before after
    ? Print only the matching part
    $ grep -o "{{pattern}}" {{file}}
    ~ extract
    ? List the files that contain a match
    $ grep -rl "{{text}}" {{folder}}
    ~ filenames only
    ? Count the matching lines
    $ grep -c "{{text}}" {{file}}
    ~ how many
    ? Search only files with a given extension
    $ grep -r --include="*.{{ext}}" "{{text}}" {{folder}}
    ~ file type filter
    ? Filter a command's output
    $ {{command}} | grep "{{text}}"
    ~ pipe

    # --- sed -----------------------------------------------------------------
    prog sed | Edit text as it streams through
    use sed [options] 'command' [file ...]
    tags replace substitute edit stream
    ? Replace text and print the result
    $ sed 's/{{old}}/{{new}}/g' {{file}}
    ~ substitute find and replace
    ? Replace text in the file itself (macOS needs the empty quotes)
    $ sed -i '' 's/{{old}}/{{new}}/g' {{file}}
    ~ in place edit substitute find and replace
    ? Print one line of a file
    $ sed -n '{{5}}p' {{file}}
    ~ show specific line number
    ? Print a range of lines
    $ sed -n '{{10}},{{20}}p' {{file}}
    ~ show lines between
    ? Delete the lines that match
    $ sed '/{{pattern}}/d' {{file}}
    ~ remove lines containing
    ? Delete one line from the file itself
    $ sed -i '' '{{3}}d' {{file}}
    ~ remove line number in place
    ? Remove trailing spaces from every line
    $ sed 's/[[:space:]]*$//' {{file}}
    ~ trim whitespace strip
    ? Use extended regular expressions
    $ sed -E 's/({{group}})/[\1]/' {{file}}
    ~ regex capture groups

    # --- find ----------------------------------------------------------------
    prog find | Search for files in a folder tree
    use find [path ...] [expression]
    tags search locate files
    ? Find files by name
    $ find {{folder}} -name "{{*.txt}}"
    ~ search locate filename
    ? Find files by name, ignoring case
    $ find {{folder}} -iname "{{*.txt}}"
    ~ case insensitive
    ? Find only files
    $ find {{folder}} -type f
    ~ no directories
    ? Find only folders
    $ find {{folder}} -type d -name "{{name}}"
    ~ directories
    ? Find files bigger than 100 MB
    $ find {{folder}} -type f -size +100M
    ~ large big huge size
    ? Find files changed in the last day
    $ find {{folder}} -type f -mtime -1
    ~ recent modified today yesterday
    ? Find files changed in the last half hour
    $ find {{folder}} -type f -mmin -30
    ~ recent minutes
    ? Find files newer than another file
    $ find {{folder}} -newer {{file}}
    ~ modified after
    ? Find empty files and folders
    $ find {{folder}} -empty
    ~ blank
    ? Look only in this folder, not below it
    $ find {{folder}} -maxdepth 1 -type f
    ~ depth shallow non recursive
    ? Run a command on every match
    $ find {{folder}} -name "{{*.log}}" -exec {{command}} {} +
    ~ for each apply
    ? Delete the files that match
    $ find {{folder}} -name "{{*.tmp}}" -delete
    ~ remove cleanup

    # --- tar -----------------------------------------------------------------
    prog tar | Make and unpack archives
    use tar -c [-z | -j | -J] -f archive file ...
    use tar -x [-f archive] [-C directory]
    tags archive compress extract tarball gzip
    ? Compress a folder into a .tar.gz
    $ tar -czf {{archive.tar.gz}} {{folder}}
    ~ zip pack gzip create
    ? Unpack a .tar.gz
    $ tar -xzf {{archive.tar.gz}}
    ~ extract unzip decompress untar
    ? Unpack an archive into a folder
    $ tar -xf {{archive.tar}} -C {{folder}}
    ~ extract destination
    ? List what is in an archive
    $ tar -tf {{archive.tar.gz}}
    ~ contents show without extracting
    ? Make an archive without compressing it
    $ tar -cf {{archive.tar}} {{folder}}
    ? Compress with bzip2
    $ tar -cjf {{archive.tar.bz2}} {{folder}}
    ? Compress with xz
    $ tar -cJf {{archive.tar.xz}} {{folder}}
    ? Unpack just one file from an archive
    $ tar -xzf {{archive.tar.gz}} {{path/in/archive}}
    ~ extract single
    ? Leave some files out of an archive
    $ tar -czf {{archive.tar.gz}} --exclude="{{*.log}}" {{folder}}
    ~ ignore skip
    ? Make an archive without the hidden ._ files macOS adds
    $ COPYFILE_DISABLE=1 tar -czf {{archive.tar.gz}} {{folder}}
    ~ appledouble metadata resource fork

    # --- unzip ---------------------------------------------------------------
    prog unzip | Unpack .zip files
    use unzip [options] archive [file ...] [-d directory]
    tags extract decompress zip
    ? Unpack a .zip here
    $ unzip {{archive.zip}}
    ~ extract decompress
    ? Unpack a .zip into a folder
    $ unzip {{archive.zip}} -d {{folder}}
    ~ extract destination
    ? List what is in a .zip
    $ unzip -l {{archive.zip}}
    ~ contents show without extracting
    ? Unpack one file from a .zip
    $ unzip {{archive.zip}} "{{path/in/archive}}"
    ~ extract single
    ? Unpack, overwriting files without asking
    $ unzip -o {{archive.zip}}
    ~ replace force
    ? Unpack quietly
    $ unzip -q {{archive.zip}}
    ~ silent

    # --- zip -----------------------------------------------------------------
    prog zip | Make .zip archives
    use zip [options] archive file ...
    tags compress archive pack
    ? Compress a folder into a .zip
    $ zip -r {{archive.zip}} {{folder}}
    ~ archive pack compress directory
    ? Compress some files into a .zip
    $ zip {{archive.zip}} {{file1}} {{file2}}
    ~ archive pack
    ? Compress a folder, leaving out .DS_Store files
    $ zip -r {{archive.zip}} {{folder}} -x "*.DS_Store"
    ~ exclude ignore
    ? Make a .zip protected by a password
    $ zip -er {{archive.zip}} {{folder}}
    ~ encrypt secure
    ? Add or update files in an existing .zip
    $ zip -u {{archive.zip}} {{file}}
    ~ append modify
    ? Remove a file from a .zip
    $ zip -d {{archive.zip}} "{{file}}"
    ~ delete

    # --- du ------------------------------------------------------------------
    prog du | Show how much disk space files use
    use du [options] [file ...]
    tags disk usage size space
    ? Show the total size of a folder
    $ du -sh {{folder}}
    ~ how big space used
    ? Show the size of everything in this folder
    $ du -sh *
    ~ each item
    ? Show the biggest items in this folder first
    $ du -sh * | sort -rh
    ~ largest heavy space hogs
    ? Show sizes one level down
    $ du -h -d 1 {{folder}}
    ~ depth subfolders
    ? Find the 20 biggest files and folders
    $ du -ah {{folder}} | sort -rh | head -n 20
    ~ largest big space hogs
    ? Show sizes in kilobytes
    $ du -sk {{folder}}
    ? Show the grand total as well
    $ du -ch {{file1}} {{file2}}
    ~ sum

    # --- df ------------------------------------------------------------------
    prog df | Show free disk space
    use df [options] [file ...]
    tags disk space free storage
    ? Show free space on every disk
    $ df -h
    ~ storage capacity available
    ? Show free space on the disk holding a path
    $ df -h {{path}}
    ~ which disk
    ? Show only local disks
    $ df -hl
    ~ no network
    ? Show inode use
    $ df -i
    ~ files count
    ? Show sizes in powers of 1000, like Finder does
    $ df -H
    ~ decimal

    # --- jq ------------------------------------------------------------------
    prog jq | Query and reshape JSON
    use jq [options] filter [file ...]
    tags json parse query
    ? Pretty-print JSON
    $ jq . {{file.json}}
    ~ format indent beautify
    ? Print one field
    $ jq '.{{key}}' {{file.json}}
    ~ get extract value
    ? Print a field as plain text, without quotes
    $ jq -r '.{{key}}' {{file.json}}
    ~ raw string unquote
    ? Print every item of an array
    $ jq '.[]' {{file.json}}
    ~ iterate each
    ? Print one field of every item in an array
    $ jq '.[].{{key}}' {{file.json}}
    ~ map pluck extract
    ? Keep the items where a field has a value
    $ jq '.[] | select(.{{key}} == "{{value}}")' {{file.json}}
    ~ filter where
    ? Count the items in an array
    $ jq 'length' {{file.json}}
    ~ how many size
    ? List the keys of an object
    $ jq 'keys' {{file.json}}
    ~ fields properties
    ? Print JSON on one line
    $ jq -c . {{file.json}}
    ~ compact minify
    ? Format the JSON a command prints
    $ {{command}} | jq .
    ~ pipe pretty

    # --- curl ----------------------------------------------------------------
    prog curl | Transfer data from or to a URL
    use curl [options] url ...
    tags http request download api fetch
    ? Fetch a URL and print it
    $ curl {{url}}
    ~ get request
    ? Save the response to a file
    $ curl -o {{file}} {{url}}
    ~ download output
    ? Download a file under its own name
    $ curl -O {{url}}
    ~ download
    ? Follow redirects
    $ curl -L {{url}}
    ~ location
    ? Show only the response headers
    $ curl -I {{url}}
    ~ head status
    ? Show only the HTTP status code
    $ curl -s -o /dev/null -w "%{http_code}\n" {{url}}
    ~ response code status check up
    ? Send JSON with a POST
    $ curl -X POST -H "Content-Type: application/json" -d '{{json}}' {{url}}
    ~ api request body
    ? Send a form field with a POST
    $ curl -d "{{name}}={{value}}" {{url}}
    ~ form data post
    ? Call an API with a bearer token
    $ curl -H "Authorization: Bearer {{token}}" {{url}}
    ~ authentication auth header
    ? Upload a file
    $ curl -F "file=@{{path}}" {{url}}
    ~ multipart form post
    ? Resume an interrupted download
    $ curl -C - -O {{url}}
    ~ continue
    ? Show the whole conversation with the server
    $ curl -v {{url}}
    ~ debug verbose headers
    ? Fetch quietly, failing on errors
    $ curl -fsSL {{url}}
    ~ silent script install

    # --- ssh -----------------------------------------------------------------
    prog ssh | Log in to another machine securely
    use ssh [options] [user@]host [command]
    tags remote login server shell
    ? Log in to a server
    $ ssh {{user}}@{{host}}
    ~ connect remote
    ? Log in on a different port
    $ ssh -p {{port}} {{user}}@{{host}}
    ? Log in with a particular key
    $ ssh -i {{~/.ssh/key}} {{user}}@{{host}}
    ~ identity private key
    ? Run one command on a server and come back
    $ ssh {{user}}@{{host}} "{{command}}"
    ~ remote execute
    ? Reach a server through another one
    $ ssh -J {{jump_host}} {{user}}@{{host}}
    ~ bastion proxy jump hop
    ? Forward a local port to a port on the server
    $ ssh -L {{8080}}:localhost:{{80}} {{user}}@{{host}}
    ~ tunnel port forward local
    ? Make a port on the server reach back to this Mac
    $ ssh -R {{8080}}:localhost:{{3000}} {{user}}@{{host}}
    ~ tunnel reverse remote forward
    ? Use the server as a SOCKS proxy
    $ ssh -D {{1080}} {{user}}@{{host}}
    ~ tunnel proxy
    ? Keep a tunnel open in the background
    $ ssh -fN -L {{8080}}:localhost:{{80}} {{user}}@{{host}}
    ~ background daemon
    ? Pass your keys along to the server
    $ ssh -A {{user}}@{{host}}
    ~ agent forwarding
    ? Show what ssh is doing, to find out why a login fails
    $ ssh -v {{user}}@{{host}}
    ~ debug troubleshoot verbose

    # --- scp -----------------------------------------------------------------
    prog scp | Copy files to or from another machine
    use scp [options] source ... target
    tags copy upload download remote transfer
    ? Upload a file
    $ scp {{file}} {{user}}@{{host}}:{{remote_path}}
    ~ send copy to server
    ? Download a file
    $ scp {{user}}@{{host}}:{{remote_file}} {{local_path}}
    ~ get copy from server
    ? Upload a folder
    $ scp -r {{folder}} {{user}}@{{host}}:{{remote_path}}
    ~ recursive directory
    ? Download a folder
    $ scp -r {{user}}@{{host}}:{{remote_folder}} {{local_path}}
    ~ recursive directory
    ? Copy using a different port
    $ scp -P {{port}} {{file}} {{user}}@{{host}}:{{remote_path}}
    ? Copy using a particular key
    $ scp -i {{~/.ssh/key}} {{file}} {{user}}@{{host}}:{{remote_path}}
    ~ identity
    ? Copy between two servers
    $ scp {{user1}}@{{host1}}:{{file}} {{user2}}@{{host2}}:{{path}}
    ~ remote to remote
    ? Compress while copying
    $ scp -C {{file}} {{user}}@{{host}}:{{remote_path}}
    ~ faster slow connection

    # --- ssh-keygen ----------------------------------------------------------
    prog ssh-keygen | Make and manage SSH keys
    use ssh-keygen [-t type] [-C comment] [-f file]
    tags key ssh identity ssh-add ssh-copy-id
    ? Make a new key
    $ ssh-keygen -t ed25519 -C "{{email}}"
    ~ generate create new ssh key pair
    ? Make an RSA key, for servers that do not take ed25519
    $ ssh-keygen -t rsa -b 4096 -C "{{email}}"
    ~ generate old
    ? Add a key to the agent and the macOS Keychain
    $ ssh-add --apple-use-keychain {{~/.ssh/id_ed25519}}
    ~ remember passphrase load
    ? Put your public key on a server, so you can log in without a password
    $ ssh-copy-id {{user}}@{{host}}
    ~ authorize install passwordless
    ? Copy your public key to the clipboard
    $ pbcopy < {{~/.ssh/id_ed25519.pub}}
    ~ github paste
    ? Show a key's fingerprint
    $ ssh-keygen -lf {{key.pub}}
    ~ hash identify
    ? Print the public key for a private key
    $ ssh-keygen -y -f {{private_key}}
    ~ recover
    ? Change a key's passphrase
    $ ssh-keygen -p -f {{private_key}}
    ~ password
    ? Forget a server's key, after it was reinstalled
    $ ssh-keygen -R {{host}}
    ~ known_hosts changed warning remove
    ? List the keys the agent holds
    $ ssh-add -l
    ~ loaded

    # --- open ----------------------------------------------------------------
    prog open | Open files, folders and apps from the terminal
    use open [options] [file ...]
    tags macos finder launch
    ? Open a file with its usual app
    $ open {{file}}
    ~ launch default
    ? Open the current folder in Finder
    $ open .
    ~ show directory
    ? Open a file with a particular app
    $ open -a "{{App Name}}" {{file}}
    ~ application launch with
    ? Show a file in Finder, selected
    $ open -R {{file}}
    ~ reveal locate
    ? Open a web page in the default browser
    $ open {{https://example.com}}
    ~ url browser
    ? Open a file in TextEdit
    $ open -e {{file}}
    ~ text editor
    ? Open a file in the default text editor
    $ open -t {{file}}
    ~ edit
    ? Start a second copy of an app
    $ open -n -a "{{App Name}}"
    ~ new instance window
    ? Open an app without bringing it to the front
    $ open -g -a "{{App Name}}"
    ~ background

    # --- defaults ------------------------------------------------------------
    prog defaults | Read and write macOS preferences
    use defaults read [domain [key]]
    use defaults write domain key value
    tags macos settings preferences plist
    ? Read all of an app's preferences
    $ defaults read {{com.apple.finder}}
    ~ show settings domain
    ? Read one preference
    $ defaults read {{domain}} {{key}}
    ~ get value
    ? Set a true or false preference
    $ defaults write {{domain}} {{key}} -bool true
    ~ boolean turn on enable
    ? Set a text preference
    $ defaults write {{domain}} {{key}} -string "{{value}}"
    ~ change
    ? Set a number preference
    $ defaults write {{domain}} {{key}} -int {{1}}
    ~ integer change
    ? Reset a preference to its default
    $ defaults delete {{domain}} {{key}}
    ~ remove undo
    ? Find a preference by name or value
    $ defaults find {{text}}
    ~ search locate
    ? Show hidden files in Finder
    $ defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder
    ~ dotfiles reveal
    ? Hide the Dock until the pointer reaches it
    $ defaults write com.apple.dock autohide -bool true && killall Dock
    ~ auto hide
    ? Save screenshots to a particular folder
    $ defaults write com.apple.screencapture location {{~/Screenshots}} && killall SystemUIServer
    ~ screen capture destination
    ? Check whether the Mac is in dark mode
    $ defaults read -g AppleInterfaceStyle
    ~ appearance theme

    # --- make ----------------------------------------------------------------
    prog make | Build things from a Makefile
    use make [options] [target ...] [VAR=value]
    tags build compile target
    ? Build the default target
    $ make
    ~ compile
    ? Build a particular target
    $ make {{target}}
    ? Build using several cores
    $ make -j{{4}}
    ~ parallel faster jobs
    ? Show what would run, without running it
    $ make -n
    ~ dry run preview
    ? Rebuild everything, even what is up to date
    $ make -B
    ~ force always
    ? Run make in another folder
    $ make -C {{folder}}
    ~ directory
    ? Use a Makefile with another name
    $ make -f {{Makefile.other}}
    ~ file
    ? Set a variable for this run
    $ make {{VAR}}={{value}}
    ~ override define
    ? Keep going after an error
    $ make -k
    ~ continue ignore
    ? Remove the build products
    $ make clean
    ~ cleanup delete

    # --- swift ---------------------------------------------------------------
    prog swift | Build, run and test Swift code
    use swift build [options]
    use swift run [options] [target] [args]
    use swift test [options]
    tags swiftpm package spm
    ? Build the package
    $ swift build
    ~ compile
    ? Build with optimisations
    $ swift build -c release
    ~ optimise optimize production
    ? Run the package's executable
    $ swift run
    ~ start
    ? Run a particular executable, with arguments
    $ swift run {{target}} {{arguments}}
    ? Run the tests
    $ swift test
    ~ unit tests
    ? Run only some tests
    $ swift test --filter {{TestName}}
    ~ single one
    ? Start a new package in this folder
    $ swift package init --type {{executable}}
    ~ create new project
    ? Fetch the dependencies
    $ swift package resolve
    ~ install download
    ? Update the dependencies to their newest allowed versions
    $ swift package update
    ~ upgrade
    ? Delete the build products
    $ swift package clean
    ~ cleanup
    ? Show the installed Swift version
    $ swift --version
    ~ which

    # --- cargo ---------------------------------------------------------------
    prog cargo | Build and manage Rust projects
    use cargo <command> [options]
    tags rust crate package
    ? Start a new project
    $ cargo new {{name}}
    ~ create init
    ? Build the project
    $ cargo build
    ~ compile
    ? Build with optimisations
    $ cargo build --release
    ~ optimise optimize production
    ? Build and run
    $ cargo run
    ~ start
    ? Run the tests
    $ cargo test
    ~ unit
    ? Run only the tests with some text in their name
    $ cargo test {{name}}
    ~ single filter
    ? Check that it compiles, without building
    $ cargo check
    ~ fast errors
    ? Add a dependency
    $ cargo add {{crate}}
    ~ install package
    ? Update the dependencies
    $ cargo update
    ~ upgrade
    ? Format the code
    $ cargo fmt
    ~ rustfmt style
    ? Look for common mistakes
    $ cargo clippy
    ~ lint
    ? Install a program written in Rust
    $ cargo install {{crate}}
    ~ binary tool
    ? Build the docs and open them
    $ cargo doc --open
    ~ documentation
    ? Delete the build products
    $ cargo clean
    ~ cleanup

    # --- npm -----------------------------------------------------------------
    prog npm | Install and run JavaScript packages
    use npm <command> [options]
    tags node javascript package
    ? Start a new package.json
    $ npm init -y
    ~ create new project
    ? Install what package.json lists
    $ npm install
    ~ dependencies
    ? Install exactly what the lock file says
    $ npm ci
    ~ clean install reproducible ci
    ? Add a package
    $ npm install {{package}}
    ~ dependency
    ? Add a package for development only
    $ npm install -D {{package}}
    ~ dev dependency save-dev
    ? Install a package for the whole machine
    $ npm install -g {{package}}
    ~ global
    ? Remove a package
    $ npm uninstall {{package}}
    ~ delete
    ? Run a script from package.json
    $ npm run {{script}}
    ~ start
    ? List the scripts a project has
    $ npm run
    ~ available commands
    ? Run the tests
    $ npm test
    ? Show which packages are out of date
    $ npm outdated
    ~ old upgrade
    ? Update the packages
    $ npm update
    ~ upgrade
    ? List the packages you installed directly
    $ npm ls --depth=0
    ~ installed top level
    ? Fix known vulnerabilities
    $ npm audit fix
    ~ security
    ? Run a program from npm without installing it
    $ npx {{package}}
    ~ execute one off
    ? Show the versions of a package
    $ npm view {{package}} versions
    ~ available releases

    # --- brew ----------------------------------------------------------------
    prog brew | Install software with Homebrew
    use brew <command> [options] [formula]
    tags homebrew package install macos
    ? Install a program
    $ brew install {{formula}}
    ~ add get
    ? Install a Mac app
    $ brew install --cask {{app}}
    ~ gui application
    ? Remove a program
    $ brew uninstall {{formula}}
    ~ delete
    ? Look for a program
    $ brew search {{text}}
    ~ find available
    ? Show what a program is
    $ brew info {{formula}}
    ~ details version
    ? Fetch the newest list of what is available
    $ brew update
    ~ refresh
    ? Upgrade everything
    $ brew upgrade
    ~ update all
    ? Upgrade one program
    $ brew upgrade {{formula}}
    ~ update
    ? Show what is out of date
    $ brew outdated
    ~ old upgradable
    ? List what is installed
    $ brew list
    ~ show installed
    ? List only what you installed, not its dependencies
    $ brew leaves
    ~ top level
    ? Show what a program depends on
    $ brew deps --tree {{formula}}
    ~ dependencies
    ? Free disk space by removing old versions
    $ brew cleanup
    ~ clean space
    ? Remove dependencies nothing needs now
    $ brew autoremove
    ~ unused orphans
    ? List background services
    $ brew services list
    ~ daemons running
    ? Start a service now and at login
    $ brew services start {{formula}}
    ~ run daemon
    ? Check Homebrew for problems
    $ brew doctor
    ~ troubleshoot

    # --- docker --------------------------------------------------------------
    prog docker | Run programs in containers
    use docker <command> [options]
    use docker run [options] image [command]
    tags container image compose
    sec Containers
    ? List running containers
    $ docker ps
    ~ show
    ? List all containers, including stopped ones
    $ docker ps -a
    ~ every
    ? Run a program in a new container and get a shell in it
    $ docker run -it --rm {{image}} {{sh}}
    ~ interactive terminal start
    ? Run a container in the background and publish a port
    $ docker run -d -p {{8080}}:{{80}} --name {{name}} {{image}}
    ~ detached expose port map
    ? Run a container with the current folder mounted
    $ docker run --rm -v "$(pwd)":/app -w /app {{image}} {{command}}
    ~ volume bind mount share
    ? Open a shell in a running container
    $ docker exec -it {{container}} {{sh}}
    ~ enter attach login
    ? Follow a container's logs
    $ docker logs -f {{container}}
    ~ output tail watch
    ? Stop a container
    $ docker stop {{container}}
    ~ kill halt
    ? Delete a container
    $ docker rm {{container}}
    ~ remove
    ? Stop every running container
    $ docker stop $(docker ps -q)
    ~ all halt
    ? Delete every stopped container
    $ docker container prune
    ~ remove cleanup
    ? Copy a file out of a container
    $ docker cp {{container}}:{{path}} {{local_path}}
    ~ download extract

    sec Images
    ? List images
    $ docker images
    ~ show
    ? Build an image from the Dockerfile in this folder
    $ docker build -t {{name}} .
    ~ create tag
    ? Download an image
    $ docker pull {{image}}
    ~ fetch
    ? Delete an image
    $ docker rmi {{image}}
    ~ remove
    ? Delete images nothing uses
    $ docker image prune
    ~ cleanup unused dangling

    sec Compose and cleanup
    ? Start the services in docker-compose.yml
    $ docker compose up -d
    ~ run background
    ? Stop and remove the services
    $ docker compose down
    ~ shut
    ? Follow the services' logs
    $ docker compose logs -f
    ~ output
    ? Show how much disk space Docker uses
    $ docker system df
    ~ storage size
    ? Free disk space by deleting what is unused
    $ docker system prune
    ~ cleanup remove

    # --- chmod ---------------------------------------------------------------
    prog chmod | Change who can read, write and run a file
    use chmod [options] mode file ...
    tags permissions access mode executable
    ? Change a file's permissions
    $ chmod {{mode}} {{file}}
    ~ set access rights modify
    ? Make a file runnable
    $ chmod +x {{file}}
    ~ executable script permission
    ? Let the owner read and write, and everyone else only read
    $ chmod 644 {{file}}
    ~ permissions default
    ? Let the owner do anything and everyone else read and run
    $ chmod 755 {{file}}
    ~ permissions folder script
    ? Make a file private to its owner
    $ chmod 600 {{file}}
    ~ ssh key secret
    ? Change a folder and everything in it
    $ chmod -R {{755}} {{folder}}
    ~ recursive
    ? Take away all access from the group and others
    $ chmod go-rwx {{file}}
    ~ private remove
    ? Let the owner write
    $ chmod u+w {{file}}
    ~ add writable
    ? Let everyone read
    $ chmod a+r {{file}}
    ~ readable all

    # --- chown ---------------------------------------------------------------
    prog chown | Change who owns a file
    use chown [options] owner[:group] file ...
    tags owner group permissions
    ? Give a file to a user
    $ chown {{user}} {{file}}
    ~ owner change
    ? Give a file to a user and a group
    $ chown {{user}}:{{group}} {{file}}
    ? Change a folder and everything in it
    $ chown -R {{user}} {{folder}}
    ~ recursive
    ? Take ownership of a folder as yourself
    $ sudo chown -R "$(whoami)" {{folder}}
    ~ fix permissions denied me
    ? Change only the group
    $ chown :{{group}} {{file}}

    # --- xargs ---------------------------------------------------------------
    prog xargs | Build commands from what another command prints
    use xargs [options] [command [argument ...]]
    tags pipe arguments batch
    ? Run a command on each line of input
    $ {{command}} | xargs {{other_command}}
    ~ pipe arguments
    ? Run a command once per item
    $ {{command}} | xargs -n 1 {{other_command}}
    ~ one at a time each
    ? Put each item where you say
    $ {{command}} | xargs -I {} {{other_command}} {}
    ~ replace placeholder substitute
    ? Handle names with spaces safely, with find
    $ find {{folder}} -name "{{*.tmp}}" -print0 | xargs -0 rm
    ~ whitespace null delete
    ? Run several at once
    $ {{command}} | xargs -P {{4}} -n 1 {{other_command}}
    ~ parallel faster
    ? Ask before each run
    $ {{command}} | xargs -p {{other_command}}
    ~ prompt confirm
    ? Show each command before running it
    $ {{command}} | xargs -t {{other_command}}
    ~ verbose echo debug

    # --- awk -----------------------------------------------------------------
    prog awk | Pick apart and total up columns of text
    use awk [-F separator] 'program' [file ...]
    tags columns fields text report
    ? Print the first column
    $ awk '{print $1}' {{file}}
    ~ field extract cut
    ? Print the last column
    $ awk '{print $NF}' {{file}}
    ~ field extract
    ? Print columns separated by a comma
    $ awk -F, '{print $2}' {{file.csv}}
    ~ csv delimiter field separator
    ? Print only the lines that match
    $ awk '/{{pattern}}/' {{file}}
    ~ filter grep
    ? Print one line of a file
    $ awk 'NR=={{5}}' {{file}}
    ~ line number specific
    ? Add up a column
    $ awk '{sum += $1} END {print sum}' {{file}}
    ~ total sum
    ? Skip the first line
    $ awk 'NR > 1' {{file}}
    ~ header
    ? Remove repeated lines, keeping the order
    $ awk '!seen[$0]++' {{file}}
    ~ unique duplicates dedupe
    ? Count the columns on each line
    $ awk '{print NF}' {{file}}
    ~ fields number
    ? Print lines longer than 80 characters
    $ awk 'length > 80' {{file}}
    ~ wide

    # --- ps ------------------------------------------------------------------
    prog ps | List the processes that are running
    use ps [options]
    tags process running cpu memory
    ? List every process
    $ ps aux
    ~ all running show
    ? Find a process by name
    $ ps aux | grep "{{name}}"
    ~ search pid
    ? Find a process id by name
    $ pgrep -fl {{name}}
    ~ pid search
    ? Show the processes using the most CPU
    $ ps aux -r | head -n 10
    ~ busy slow cpu hog top
    ? Show the processes using the most memory
    $ ps aux -m | head -n 10
    ~ ram hog top
    ? Show one process
    $ ps -p {{pid}}
    ~ single pid
    ? Show how long each process has been running
    $ ps -axo pid,etime,command
    ~ uptime elapsed age
    ? Show a process and what started it
    $ ps -o pid,ppid,command -p {{pid}}
    ~ parent

    # --- kill ----------------------------------------------------------------
    prog kill | Stop processes
    use kill [-signal] pid ...
    use killall [-signal] name ...
    tags killall pkill stop terminate process signal
    ? Ask a process to quit
    $ kill {{pid}}
    ~ stop terminate end
    ? Force a process to quit
    $ kill -9 {{pid}}
    ~ stop frozen hung stuck sigkill
    ? Quit every process with a name
    $ killall {{name}}
    ~ stop all
    ? Force every process with a name to quit
    $ killall -9 {{name}}
    ~ frozen hung stuck
    ? Quit processes whose command line contains some text
    $ pkill -f "{{text}}"
    ~ match pattern
    ? Stop whatever is using a port
    $ lsof -ti :{{port}} | xargs kill
    ~ listening address already in use free
    ? Force whatever is using a port to stop
    $ lsof -ti :{{port}} | xargs kill -9
    ~ listening address already in use free
    ? Make a process reload its settings
    $ kill -HUP {{pid}}
    ~ reload restart config
    ? Restart the Dock
    $ killall Dock
    ~ frozen macos
    ? Restart Finder
    $ killall Finder
    ~ frozen macos
    ? Pause a process, then let it carry on
    $ kill -STOP {{pid}} && kill -CONT {{pid}}
    ~ suspend resume

    # --- lsof ----------------------------------------------------------------
    prog lsof | List open files and the ports programs use
    use lsof [options] [file ...]
    tags ports network listening files
    ? Show what is using a port
    $ lsof -i :{{port}}
    ~ listening who
    ? List every program listening on a port
    $ lsof -nP -iTCP -sTCP:LISTEN
    ~ servers open ports network
    ? Print only the id of what is using a port
    $ lsof -ti :{{port}}
    ~ pid
    ? Show the files and connections a process has open
    $ lsof -p {{pid}}
    ~ handles sockets
    ? Show which process has a file open
    $ lsof {{file}}
    ~ locked busy in use
    ? Show everything open under a folder
    $ lsof +D {{folder}}
    ~ busy unmount
    ? Show everything a user has open
    $ lsof -u {{user}}
    ? Show the network connections
    $ lsof -i -P -n
    ~ sockets established

    # --- rsync ---------------------------------------------------------------
    prog rsync | Copy files, sending only what has changed
    use rsync [options] source ... target
    tags sync backup copy mirror remote
    ? Copy a folder, keeping dates and permissions
    $ rsync -av {{source}}/ {{target}}/
    ~ sync backup archive
    ? Upload a folder to a server
    $ rsync -avz {{folder}} {{user}}@{{host}}:{{remote_path}}
    ~ send copy remote
    ? Download a folder from a server
    $ rsync -avz {{user}}@{{host}}:{{remote_path}} {{local_path}}
    ~ get copy remote
    ? Make the target match the source, deleting extras
    $ rsync -av --delete {{source}}/ {{target}}/
    ~ mirror sync exact
    ? Show what would be copied, without copying
    $ rsync -avn {{source}}/ {{target}}/
    ~ dry run preview
    ? Show progress, and keep partly copied files
    $ rsync -avP {{source}} {{target}}
    ~ resume progress large
    ? Leave some files out
    $ rsync -av --exclude="{{pattern}}" {{source}}/ {{target}}/
    ~ ignore skip
    ? Copy over ssh on another port
    $ rsync -av -e "ssh -p {{port}}" {{source}} {{user}}@{{host}}:{{remote_path}}
    ~ remote port

    # --- tmux ----------------------------------------------------------------
    prog tmux | Keep terminal sessions alive and split the screen
    use tmux [command [flags]]
    tags terminal multiplexer session screen
    ? Start a named session
    $ tmux new -s {{name}}
    ~ create new
    ? List the sessions
    $ tmux ls
    ~ show running
    ? Attach to a session
    $ tmux attach -t {{name}}
    ~ reconnect resume
    ? Attach to a session, or start it if there is none
    $ tmux new -As {{name}}
    ~ create reconnect
    ? Close a session
    $ tmux kill-session -t {{name}}
    ~ end delete
    ? Rename a session
    $ tmux rename-session -t {{old}} {{new}}
    ? Split the window side by side
    $ tmux split-window -h
    ~ pane vertical
    ? Split the window one above the other
    $ tmux split-window -v
    ~ pane horizontal
    ? Reload the tmux settings
    $ tmux source-file ~/.tmux.conf
    ~ config refresh
    ? Close every session
    $ tmux kill-server
    ~ everything stop

    # --- ping ----------------------------------------------------------------
    prog ping | Check that a machine answers
    use ping [options] host
    tags network connectivity latency
    ? Check that a host is reachable
    $ ping {{host}}
    ~ up online connection
    ? Send four pings and stop
    $ ping -c 4 {{host}}
    ~ count limited
    ? Send a ping every two seconds
    $ ping -i 2 {{host}}
    ~ interval
    ? Send one ping, and give up after a few seconds
    $ ping -c 1 -t 3 {{host}}
    ~ timeout single
    ? Print only the summary
    $ ping -c 4 -q {{host}}
    ~ quiet average latency

    # --- pbcopy --------------------------------------------------------------
    prog pbcopy | Use the clipboard from the terminal
    use pbcopy < file
    use pbpaste
    tags clipboard copy paste pbpaste macos
    ? Copy a file's contents to the clipboard
    $ pbcopy < {{file}}
    ~ yank
    ? Copy a command's output to the clipboard
    $ {{command}} | pbcopy
    ~ pipe
    ? Copy the current folder's path
    $ pwd | pbcopy
    ~ directory location
    ? Copy some text
    $ printf %s "{{text}}" | pbcopy
    ~ string
    ? Print what is on the clipboard
    $ pbpaste
    ~ paste show
    ? Save the clipboard to a file
    $ pbpaste > {{file}}
    ~ paste write
    ? Run a command on the clipboard's text
    $ pbpaste | {{command}}
    ~ pipe paste
    ? Sort the lines on the clipboard
    $ pbpaste | sort | pbcopy
    ~ transform clean

    # --- caffeinate ----------------------------------------------------------
    prog caffeinate | Keep the Mac awake
    use caffeinate [options] [command]
    tags sleep awake macos
    ? Keep the Mac awake until you press Ctrl-C
    $ caffeinate
    ~ prevent sleep stay on
    ? Keep it awake for a while, in seconds
    $ caffeinate -t {{3600}}
    ~ hour timer
    ? Keep it awake while a command runs
    $ caffeinate -i {{command}}
    ~ long running job
    ? Keep it awake until a process ends
    $ caffeinate -w {{pid}}
    ~ wait
    ? Keep the screen from sleeping
    $ caffeinate -d
    ~ display
    ? Wake the screen up
    $ caffeinate -u -t 2
    ~ display on

    # --- mdfind --------------------------------------------------------------
    prog mdfind | Search with Spotlight
    use mdfind [options] query
    tags spotlight search macos index
    ? Search for text anywhere
    $ mdfind "{{text}}"
    ~ spotlight find
    ? Search by file name
    $ mdfind -name "{{name}}"
    ~ filename locate
    ? Search only inside one folder
    $ mdfind -onlyin {{folder}} "{{text}}"
    ~ directory limit
    ? Find files bigger than 100 MB
    $ mdfind "kMDItemFSSize > 104857600"
    ~ large big huge size
    ? Find all PDFs
    $ mdfind "kMDItemContentType == 'com.adobe.pdf'"
    ~ kind type documents
    ? Count the matches
    $ mdfind -count "{{text}}"
    ~ how many
    ? Find an app by name
    $ mdfind "kMDItemKind == 'Application' && kMDItemDisplayName == '*{{name}}*'"
    ~ applications installed

    # --- diskutil ------------------------------------------------------------
    prog diskutil | Manage disks and volumes on a Mac
    use diskutil <verb> [options]
    tags disk volume usb eject macos
    ? List the disks and their volumes
    $ diskutil list
    ~ drives partitions show
    ? Show details about a disk or volume
    $ diskutil info {{disk}}
    ~ information
    ? Unmount a volume
    $ diskutil unmount {{volume}}
    ~ eject
    ? Unmount every volume on a disk
    $ diskutil unmountDisk {{disk}}
    ~ eject usb
    ? Eject a disk
    $ diskutil eject {{disk}}
    ~ usb safely remove
    ? Mount a volume
    $ diskutil mount {{disk}}
    ~ connect
    ? Check a volume for errors
    $ diskutil verifyVolume {{volume}}
    ~ repair health
    ? Show the APFS containers and volumes
    $ diskutil apfs list
    ~ space snapshot
    """#
}
