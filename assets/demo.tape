# The README demo, as a script. Regenerate it with:
#
#   brew install vhs                  # or see github.com/charmbracelet/vhs
#   export DEMO_REPO=~/src/jellyfin   # any public .NET solution; see below
#   vhs assets/demo.tape
#
# Recorded against a jellyfin checkout: public, 41 projects, central package
# management, and a few packages behind their latest version. Restore it first:
#
#   git clone --depth 1 https://github.com/jellyfin/jellyfin "$DEMO_REPO"
#   cd "$DEMO_REPO" && dotnet restore
#
# The demo really updates Polly and installs Bogus, so it changes the checkout:
# reset it between takes (`git checkout -- . && git clean -fd` inside it, never
# in a checkout you work in).
#
# assets/demo-config.lua is the Neovim configuration used here. Copy it to
# ~/.config/nuget-demo/init.lua.
#
# VHS emits a frame when the screen changes, so a long Sleep over a still screen
# shortens in the recording. Tune the Sleeps by looking at the output.

Output "assets/demo.gif"
Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1500
Set Height 860
Set Theme "TokyoNight"
Set Padding 12

Hide
Type `cd "$DEMO_REPO" && clear`
Enter
Type "NVIM_APPNAME=nuget-demo nvim Directory.Packages.props"
Enter
Sleep 5s
Show

# --- 1. the whole solution in one window -----------------------------------
Sleep 1s
Type ":Nuget"
Sleep 700ms
Enter
Sleep 6500ms

# --- 2. details follow the cursor ------------------------------------------
Type@400ms "jjjjjj"
Sleep 2500ms

# --- 3. filter by id --------------------------------------------------------
Type "/"
Sleep 400ms
Type@110ms "Swashbuckle"
Sleep 1200ms
Enter
Sleep 3s

# --- 4. update, written where the version lives -----------------------------
Type "3"
Sleep 2s
Type@250ms "jjjjjjj"
Sleep 1200ms
Type "u"
Sleep 12s

# --- 5. search and install ---------------------------------------------------
Type "1"
Sleep 1s
Type "/"
Sleep 300ms
Type@150ms "Bogus"
Sleep 4s
Enter
Sleep 2500ms
Enter
Sleep 1200ms
Type@250ms "jjjj"
Space
Sleep 1s
Enter
Sleep 12s

# --- 6. the keys -------------------------------------------------------------
Type "?"
Sleep 4s
Type "q"
Sleep 600ms

# --- 7. and Directory.Packages.props has both changes ------------------------
Type "q"
Sleep 1s
Type "/Polly"
Enter
Type "zz"
Sleep 2500ms
Type "/Bogus"
Enter
Sleep 3s
