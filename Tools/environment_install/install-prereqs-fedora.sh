#!/usr/bin/env bash
echo "---------- $0 start ----------"
set -e
set -x

if [ $EUID == 0 ]; then
    echo "Please do not run this script as root; don't sudo it!"
    exit 1
fi

OPT="/opt"
# Ardupilot Tools
ARDUPILOT_TOOLS="Tools/autotest"

ASSUME_YES=false
QUIET=false
sep="##############################################"

OPTIND=1  # Reset in case getopts has been used previously in the shell.
while getopts "yq" opt; do
    case "$opt" in
        \?)
            exit 1
            ;;
        y)  ASSUME_YES=true
            ;;
        q)  QUIET=true
            ;;
    esac
done

DNF="sudo dnf install"
if $ASSUME_YES; then
    DNF="$DNF -y"
fi
if $QUIET; then
    DNF="$DNF -q"
fi

PIP="python3 -m pip"
if $QUIET; then
    PIP="$PIP -q"
fi

function package_is_installed() {
    rpm -q $1 &>/dev/null
}

function heading() {
    echo "$sep"
    echo $*
    echo "$sep"
}

# Base development packages
BASE_PKGS="@development-tools ccache git wget valgrind screen gcc-c++ gawk make rsync"

# SITL (Software In The Loop) packages
SITL_PKGS="python3 python3-devel python3-pip python3-setuptools python3-wheel"
SITL_PKGS="$SITL_PKGS python3-numpy python3-pyparsing python3-psutil"
SITL_PKGS="$SITL_PKGS libxml2-devel libxslt-devel"
SITL_PKGS="$SITL_PKGS xterm xorg-x11-fonts-misc SFML-devel"
SITL_PKGS="$SITL_PKGS freetype-devel libpng-devel SDL2-devel SDL2_image-devel SDL2_mixer-devel SDL2_ttf-devel portmidi-devel"

# Python packages to install via pip
PYTHON_PKGS="future lxml pymavlink MAVProxy pexpect argparse pyparsing geocoder pyserial empy==3.3.4 ptyprocess dronecan"
PYTHON_PKGS="$PYTHON_PKGS flake8 junitparser matplotlib scipy opencv-python pygame intelhex psutil pyyaml packaging"

# ARM toolchain for STM32 boards
ARM_ROOT="gcc-arm-none-eabi-10-2020-q4-major"
ARM_TARBALL="$ARM_ROOT-x86_64-linux.tar.bz2"
ARM_TARBALL_URL="https://firmware.ardupilot.org/Tools/STM32-tools/$ARM_TARBALL"
ARM_TARBALL_CHECKSUM="21134caa478bbf5352e239fbc6e2da3038f8d2207e089efc96c3b55f1edcd618"

# ARM Linux toolchain
ARM_LINUX_ROOT="gcc-linaro-7.5.0-2019.12-x86_64_arm-linux-gnueabihf"
ARM_LINUX_GCC_URL="https://releases.linaro.org/components/toolchain/binaries/7.5-2019.12/arm-linux-gnueabihf/gcc-linaro-7.5.0-2019.12-x86_64_arm-linux-gnueabihf.tar.xz"
ARM_LINUX_TARBALL="gcc-linaro-7.5.0-2019.12-x86_64_arm-linux-gnueabihf.tar.xz"

function maybe_prompt_user() {
    if $ASSUME_YES; then
        return 0
    else
        read -p "$1"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            return 0
        else
            return 1
        fi
    fi
}

heading "Add user to dialout group to allow managing serial ports"
sudo usermod -a -G dialout "$USER"
echo "Done!"

heading "Installing base packages"
$DNF $BASE_PKGS
echo "Done!"

heading "Installing SITL packages"
$DNF $SITL_PKGS
echo "Done!"

SHELL_LOGIN=".profile"

# Check for Docker environment
IS_DOCKER=false
if [[ ${AP_DOCKER_BUILD:-0} -eq 1 ]] || [[ -f /.dockerenv ]] || grep -Eq '(lxc|docker)' /proc/1/cgroup ; then
    IS_DOCKER=true
fi

if $IS_DOCKER; then
    echo "Inside docker, we add the tools path into .bashrc directly"
    SHELL_LOGIN=".ardupilot_env"
    echo "# ArduPilot env file. Need to be loaded by your Shell." > ~/$SHELL_LOGIN
fi

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
ARDUPILOT_ROOT=$(realpath "$SCRIPT_DIR/../../")

heading "Setting up Python virtual environment"
python3 -m venv --system-site-packages "$HOME"/venv-ardupilot

# activate it:
SOURCE_LINE="source $HOME/venv-ardupilot/bin/activate"
$SOURCE_LINE

if [[ -z "${DO_PYTHON_VENV_ENV}" ]] && maybe_prompt_user "Make ArduPilot venv default for python [N/y]?" ; then
    DO_PYTHON_VENV_ENV=1
fi

if [[ $DO_PYTHON_VENV_ENV -eq 1 ]]; then
    echo "$SOURCE_LINE" >> ~/$SHELL_LOGIN
else
    echo "Please use \`$SOURCE_LINE\` to activate the ArduPilot venv"
fi
echo "Done!"

heading "Installing Python packages"
$PIP install -U pip packaging setuptools wheel
$PIP install -U attrdict3

# Install Python packages one at a time for better error reporting
for PACKAGE in $PYTHON_PKGS; do
    if [ "$PACKAGE" == "wxpython" ]; then
        echo "##### $PACKAGE takes a *VERY* long time to install (~30 minutes). Be patient."
    fi
    $PIP install -U $PACKAGE
done
echo "Done!"

heading "Setting up ccache for ARM compilers"
(
    cd /usr/lib64/ccache
    for C in arm-none-eabi-g++ arm-none-eabi-gcc arm-linux-gnueabihf-g++ arm-linux-gnueabihf-gcc; do
        if [ ! -f "$C" ]; then
            sudo ln -s ../../bin/ccache "$C"
        fi
    done
)

ccache --set-config sloppiness=file_macro,locale,time_macros
ccache --set-config ignore_options="--specs=nano.specs --specs=nosys.specs"
echo "Done!"

# Install ARM none-eabi toolchain
if [[ -z "${DO_AP_STM_ENV}" ]] && maybe_prompt_user "Install ArduPilot STM32 toolchain [N/y]?" ; then
    DO_AP_STM_ENV=1
fi

if [[ $DO_AP_STM_ENV -eq 1 ]]; then
    heading "Installing ARM none-eabi toolchain for STM32 boards"
    if [ ! -d $OPT/$ARM_ROOT ]; then
        (
            cd $OPT
            
            # Check if file exists and verify checksum
            download_required=false
            if [ -e "$ARM_TARBALL" ]; then
                echo "File exists. Verifying checksum..."
                
                # Calculate the checksum of the existing file
                ACTUAL_CHECKSUM=$(sha256sum "$ARM_TARBALL" | awk '{ print $1 }')
                
                # Compare the actual checksum with the expected one
                if [ "$ACTUAL_CHECKSUM" == "$ARM_TARBALL_CHECKSUM" ]; then
                    echo "Checksum valid. No need to redownload."
                else
                    echo "Checksum invalid. Redownloading the file..."
                    download_required=true
                    sudo rm $ARM_TARBALL
                fi
            else
                echo "File does not exist. Downloading..."
                download_required=true
            fi
            
            if $download_required; then
                sudo wget -O "$ARM_TARBALL" --progress=dot:giga $ARM_TARBALL_URL
            fi
            
            sudo tar xjf ${ARM_TARBALL}
            sudo rm ${ARM_TARBALL}
        )
    fi
    echo "Done!"
fi

# Install ARM Linux toolchain
if [[ -z "${DO_ARM_LINUX}" ]] && maybe_prompt_user "Install ARM Linux toolchain [N/y]?" ; then
    DO_ARM_LINUX=1
fi

if [[ $DO_ARM_LINUX -eq 1 ]]; then
    heading "Installing ARM Linux toolchain"
    if [ ! -d $OPT/$ARM_LINUX_ROOT ]; then
        (
            cd $OPT
            sudo wget --progress=dot:giga "${ARM_LINUX_GCC_URL}"
            sudo tar xf ${ARM_LINUX_TARBALL}
            sudo rm ${ARM_LINUX_TARBALL}
        )
    fi
    echo "Done!"
fi

heading "Removing modemmanager and brltty packages that could conflict with firmware uploading"
if package_is_installed "ModemManager"; then
    sudo dnf remove -y ModemManager
fi
if package_is_installed "brltty"; then
    sudo dnf remove -y brltty
fi
echo "Done!"

heading "Adding ArduPilot Tools to environment"

if [[ $DO_AP_STM_ENV -eq 1 ]]; then
    exportline="export PATH=$OPT/$ARM_ROOT/bin:\$PATH"
    if ! grep -Fxq "$exportline" ~/$SHELL_LOGIN 2>/dev/null; then
        if maybe_prompt_user "Add $OPT/$ARM_ROOT/bin to your PATH [N/y]?" ; then
            echo "$exportline" >> ~/$SHELL_LOGIN
            eval "$exportline"
        else
            echo "Skipping adding $OPT/$ARM_ROOT/bin to PATH."
        fi
    fi
fi

if [[ $DO_ARM_LINUX -eq 1 ]]; then
    exportline1="export PATH=$OPT/$ARM_LINUX_ROOT/bin:\$PATH"
    if ! grep -Fxq "$exportline1" ~/$SHELL_LOGIN 2>/dev/null; then
        if maybe_prompt_user "Add $OPT/$ARM_LINUX_ROOT/bin to your PATH [N/y]?" ; then
            echo "$exportline1" >> ~/$SHELL_LOGIN
            eval "$exportline1"
        else
            echo "Skipping adding $OPT/$ARM_LINUX_ROOT/bin to PATH."
        fi
    fi
fi

exportline2="export PATH=\"$ARDUPILOT_ROOT/$ARDUPILOT_TOOLS:\"\$PATH"
if ! grep -Fxq "$exportline2" ~/$SHELL_LOGIN 2>/dev/null; then
    if maybe_prompt_user "Add $ARDUPILOT_ROOT/$ARDUPILOT_TOOLS to your PATH [N/y]?" ; then
        echo "$exportline2" >> ~/$SHELL_LOGIN
        eval "$exportline2"
    else
        echo "Skipping adding $ARDUPILOT_ROOT/$ARDUPILOT_TOOLS to PATH."
    fi
fi

if [[ $SKIP_AP_COMPLETION_ENV -ne 1 ]]; then
    exportline3="source \"$ARDUPILOT_ROOT/Tools/completion/completion.bash\""
    if ! grep -Fxq "$exportline3" ~/.bashrc 2>/dev/null; then
        if maybe_prompt_user "Add ArduPilot Bash Completion to your bash shell [N/y]?" ; then
            echo "$exportline3" >> ~/.bashrc
            eval "$exportline3"
        else
            echo "Skipping adding ArduPilot Bash Completion."
        fi
    fi
fi

exportline4="export PATH=/usr/lib64/ccache:\$PATH"
if ! grep -Fxq "$exportline4" ~/$SHELL_LOGIN 2>/dev/null; then
    if maybe_prompt_user "Append CCache to your PATH [N/y]?" ; then
        echo "$exportline4" >> ~/$SHELL_LOGIN
        eval "$exportline4"
    else
        echo "Skipping appending CCache to PATH."
    fi
fi
echo "Done!"

if [[ $SKIP_AP_GIT_CHECK -ne 1 ]]; then
    if [ -d "$ARDUPILOT_ROOT/.git" ]; then
        heading "Update git submodules"
        cd "$ARDUPILOT_ROOT"
        git submodule update --init --recursive
        echo "Done!"
    fi
fi

if $IS_DOCKER; then
    echo "Finalizing ArduPilot env for Docker"
    echo "source ~/.ardupilot_env" >> ~/.bashrc
fi

echo "---------- $0 end ----------"
echo "Done. Please log out and log in again."