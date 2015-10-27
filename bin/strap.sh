#!/bin/bash
#/ Usage: bin/strap.sh [--debug]
#/ Install development dependencies on Mac OS X.
set -e

[ "$1" = "--debug" ] && STRAP_DEBUG="1"
STRAP_SUCCESS=""

cleanup() {
  rm -f "$CLT_PLACEHOLDER" "$STRAP_BREWFILE"
  if [ -z "$STRAP_SUCCESS" ]; then
    if [ -n "$STRAP_STEP" ]; then
      echo "!!! $STRAP_STEP FAILED" >&2
    else
      echo "!!! FAILED" >&2
    fi
    if [ -z "$STRAP_DEBUG" ]; then
      echo "!!! Run '$0 --debug' for debugging output." >&2
      echo "!!! If you're stuck: file an issue with debugging output at:" >&2
      echo "!!!   $STRAP_ISSUES_URL" >&2
    fi
  fi
}

trap "cleanup" EXIT

if [ -n "$STRAP_DEBUG" ]; then
  set -x
else
  STRAP_QUIET_FLAG="-q"
  Q="$STRAP_QUIET_FLAG"
fi

STDIN_FILE_DESCRIPTOR="0"
[ -t "$STDIN_FILE_DESCRIPTOR" ] && STRAP_INTERACTIVE="1"

STRAP_GIT_NAME=
STRAP_GIT_EMAIL=
STRAP_GITHUB_USER=
STRAP_GITHUB_TOKEN=
STRAP_ISSUES_URL="https://github.com/mikemcquaid/strap/issues/new"

abort() { STRAP_STEP="";   echo "!!! $@" >&2; exit 1; }
log()   { STRAP_STEP="$@"; echo "--> $@"; }
logn()  { STRAP_STEP="$@"; printf -- "--> $@ "; }
logk()  { STRAP_STEP="";   echo "OK"; }

sw_vers -productVersion | grep $Q -E "^10.(9|10|11)" || {
  abort "Run Strap on Mac OS X 10.9/10/11."
}

[ "$USER" = "root" ] && abort "Run Strap as yourself, not root."
groups | grep $Q admin || abort "Add $USER to the admin group."

# Initialise sudo now to save prompting later.
log "Enter your password (for sudo access):"
sudo -k
sudo /usr/bin/true
logk

# Set some basic security settings.
logn "Configuring security settings:"
defaults write com.apple.Safari \
  com.apple.Safari.ContentPageGroupIdentifier.WebKit2JavaEnabled \
  -bool false
defaults write com.apple.Safari \
  com.apple.Safari.ContentPageGroupIdentifier.WebKit2JavaEnabledForLocalFiles \
  -bool false
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0
sudo defaults write /Library/Preferences/com.apple.alf globalstate -int 1

if [ -n "$STRAP_GIT_NAME" ] && [ -n "$STRAP_GIT_EMAIL" ]; then
  sudo defaults write /Library/Preferences/com.apple.loginwindow \
    LoginwindowText \
    "Found this computer? Please contact $STRAP_GIT_NAME at $STRAP_GIT_EMAIL."
fi
logk

# Check and enable full-disk encryption.
logn "Checking full-disk encryption status:"
if fdesetup status | grep $Q -E "FileVault is (On|Off, but will be enabled after the next restart)."; then
  logk
elif [ -n "$STRAP_CI" ]; then
  echo
  logn "Skipping full-disk encryption for CI"
elif [ -n "$STRAP_INTERACTIVE" ]; then
  echo
  logn "Enabling full-disk encryption on next reboot:"
  sudo fdesetup enable -user "$USER" \
    | tee ~/Desktop/"FileVault Recovery Key.txt"
  logk
else
  echo
  abort 'Run `sudo fdesetup enable -user "$USER"` to enable full-disk encryption.'
fi

# Install the Xcode Command Line Tools if Xcode isn't installed.
DEVELOPER_DIR=$("xcode-select" -print-path 2>/dev/null || true)
[ -z "$DEVELOPER_DIR" ] || ! [ -f "$DEVELOPER_DIR/usr/bin/git" ] && {
  log "Installing the Xcode Command Line Tools:"
  CLT_PLACEHOLDER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  sudo touch "$CLT_PLACEHOLDER"
  CLT_PACKAGE=$(softwareupdate -l | \
                grep -B 1 -E "Command Line (Developer|Tools)" | \
                awk -F"*" '/^ +\*/ {print $2}' | sed 's/^ *//' | head -n1)
  sudo softwareupdate -i "$CLT_PACKAGE"
  sudo rm -f "$CLT_PLACEHOLDER"
  logk
}

# Check if the Xcode license is agreed to and agree if not.
/usr/bin/xcrun clang 2>&1 | grep $Q license && {
  if [ -n "$STRAP_INTERACTIVE" ]; then
    logn "Asking for Xcode license confirmation:"
    sudo xcodebuild -license
    logk
  else
    abort 'Run `sudo xcodebuild -license` to agree to the Xcode license.'
  fi
}

# Setup Git
logn "Configuring Git:"
if [ -n "$STRAP_GIT_NAME" ] && ! git config user.name >/dev/null; then
  git config --global user.name "$STRAP_GIT_NAME"
fi

if [ -n "$STRAP_GIT_EMAIL" ] && ! git config user.email >/dev/null; then
  git config --global user.email "$STRAP_GIT_EMAIL"
fi

if [ -n "$STRAP_GITHUB_USER" ] && [ -n "$STRAP_GITHUB_TOKEN" ] \
  && git credential-osxkeychain 2>&1 | grep $Q "git.credential-osxkeychain"
then
  if [ "$(git config credential.helper)" != "osxkeychain" ]
  then
    git config --global credential.helper osxkeychain
  fi

  if [ -z "$(printf "protocol=https\nhost=github.com\n" | git credential-osxkeychain get)" ]
  then
    printf "protocol=https\nhost=github.com\nusername=$STRAP_GITHUB_USER\npassword=$STRAP_GITHUB_TOKEN\n" \
      | git credential-osxkeychain store
  fi
fi
logk

# Setup Homebrew directories and permissions.
logn "Installing Homebrew:"
HOMEBREW_PREFIX="/usr/local"
HOMEBREW_CACHE="/Library/Caches/Homebrew"
for dir in "$HOMEBREW_PREFIX" "$HOMEBREW_CACHE"; do
  [ -d "$dir" ] || sudo mkdir -p "$dir"
  sudo chown -R $USER:admin "$dir"
done

# Download Homebrew.
export GIT_DIR="$HOMEBREW_PREFIX/.git" GIT_WORK_TREE="$HOMEBREW_PREFIX"
git init $Q
git config remote.origin.url "https://github.com/Homebrew/homebrew"
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git rev-parse --verify --quiet origin/master >/dev/null || {
  git fetch $Q origin master:refs/remotes/origin/master --no-tags --depth=1
  git reset $Q --hard origin/master
}
sudo chmod g+rwx "$HOMEBREW_PREFIX"/* "$HOMEBREW_PREFIX"/.??*
unset GIT_DIR GIT_WORK_TREE
logk

# Install Homebrew Bundle, Cask, Services and Versions tap.
log "Installing Homebrew taps and extensions:"
export PATH="$HOMEBREW_PREFIX/bin:$PATH"
brew update
brew tap | grep -i $Q Homebrew/bundle || brew tap Homebrew/bundle
STRAP_BREWFILE="/tmp/Brewfile.strap"
cat > "$STRAP_BREWFILE" <<EOF
tap 'caskroom/cask'
tap 'homebrew/services'
tap 'homebrew/versions'
brew 'caskroom/cask/brew-cask'
EOF
brew bundle --file="$STRAP_BREWFILE"
rm -f "$STRAP_BREWFILE"
logk

# Use pf packet filter to forward ports 80 and 443.
logn "Forwarding local ports 80 to 8080 and 443 to 8443:"
cat <<EOF | sudo tee /etc/pf.anchors/dev.strap >/dev/null
rdr pass inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080
rdr pass inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443
EOF
grep $Q "dev.strap" /etc/pf.conf || {
  sudo perl -pi \
    -e 's/(rdr-anchor.*)/\1\nrdr-anchor "dev.strap"/g;' \
    -e 's|(load anchor.*)|\1\nload anchor "dev.strap" from "/etc/pf.anchors/dev.strap"|g' \
    /etc/pf.conf
}
cat <<EOF | sudo tee /Library/LaunchDaemons/dev.strap.pf.plist >/dev/null
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE plist PUBLIC "-//Apple Computer/DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.strap.pf.plist</string>
  <key>Program</key>
  <string>/sbin/pfctl</string>
  <key>ProgramArguments</key>
  <array>
    <string>/sbin/pfctl</string>
    <string>-e</string>
    <string>-f</string>
    <string>/etc/pf.conf</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>ServiceDescription</key>
  <string>FreeBSD Packet Filter (pf) daemon</string>
  <key>StandardErrorPath</key>
  <string>/var/log/pf.log</string>
  <key>StandardOutPath</key>
  <string>/var/log/pf.log</string>
</dict>
</plist>
EOF
sudo launchctl load /Library/LaunchDaemons/dev.strap.pf.plist 2>/dev/null
logk

# Check and install any remaining software updates.
logn "Checking for software updates:"
if softwareupdate -l 2>&1 | grep $Q "No new software available."; then
  logk
else
  echo
  log "Installing software updates:"
  if [ -z "$STRAP_CI" ]; then
    sudo softwareupdate --install --all
  else
    echo "Skipping software updates for CI"
  fi
  logk
fi

# Revoke sudo access again.
sudo -k

# User brewfile
if [ -n "$STRAP_GITHUB_USER" ]; then

  # Get remote Brewfile
  if [ ! -d "$HOME/.homebrew-brewfile" ]; then
    REPO_URL="https://github.com/$STRAP_GITHUB_USER/homebrew-brewfile"
    STATUS_CODE=$(curl --silent --write-out "%{http_code}" --output /dev/null $REPO_URL/blob/HEAD/.Brewfile)
    if [ "$STATUS_CODE" -eq 200 ]; then
      logn "Cloning user Brewfile from GitHub:"
      git clone -q $REPO_URL ~/.homebrew-brewfile
      logk

    fi
  else
    logn "Updating user Brewfile from GitHub:"
    cd ~/.homebrew-brewfile
    git pull -q
    logk
  fi

  # Symlink .Brewfile
  if [ -f "$HOME/.homebrew-brewfile/.Brewfile" ]; then
    logn "Symlinking user Brewfile from ~/.homebrew-brewfile/.Brewfile to ~/.Brewfile:"
    ln -sf ~/.homebrew-brewfile/.Brewfile ~/.Brewfile
    logk
  fi

  # Install user brewfile
  logn "Installing from user Brewfile:"
  if [ -f "$HOME/.Brewfile" ]; then
    log ""
    brew bundle --global
    logk
  else
    echo "skipped"
  fi
fi

STRAP_SUCCESS="1"
log 'Finished! Install additional software with `brew install` and `brew cask install`.'
