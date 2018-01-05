#!/bin/bash
#set -x
set -Ee

function go_into_the_light_carol_anne {
    echo
    echo "Premature death..."
    if [[ -n $lock_file ]] && [[ -f $lock_file ]]; then
        echo "Removing current lock file: $lock_file"
        rm -f "$lock_file"
    else
        echo "No lock files were in use at the time."
    fi
    exit 1
}

# Immediately die on any non-zero return code
trap go_into_the_light_carol_anne ERR SIGINT SIGTERM

# Get configuration
source $(dirname $0)/build.env
printenv | sort
echo
echo

# Globals
ruler=$(printf '=%.0s' {1..79})
topdir="$(pwd)"
sdir="$topdir/src"
bdir="$topdir/build"
ldir="$topdir/lock_files"
pkgdir=''
lock_file=''
skipped=0
build_no_popd=0
patch_url='http://www.stsci.edu/~jhunk/pacman/toolchain'

# Obligatory file system safety-check
if [[ $topdir == / ]]; then
    echo "FATAL: \$topdir is the root of the file system"
    echo "FATAL: I refuse to perform builds at this level. Place $(basename $0) somewhere much deeper."
    exit 255
fi

# On failure you'll likely want to examine the build directory, so only nuke it on a subsequent run
if [[ -d $bdir ]]; then
    echo Purging build directory...
    rm -rf "$bdir"
fi

# [Re]create required directories
mkdir -p $PREFIX \
    $sdir \
    $bdir \
    $ldir

# Assimilate known-good SSL CA certs for use with OpenSSL/CURL
if [ ! -f $sdir/cacert.pem ]; then
    pushd $sdir &>/dev/null
        /usr/bin/curl \
            --remote-name \
            --time-cond cacert.pem \
            https://curl.haxx.se/ca/cacert.pem
    popd
fi

function fetch {
    # generic http[s] downloading:
    #   fetch "http://whatever.com/tarball.[{tar.{gz,bz2,xz}}|{zip}]"
    #
    # generic git repository cloning:
    #   fetch "http://whatever.com/repo/project.git" "{revision|tag|branch}"
    #
    # Files and directories are stored in $sdir (the "src" directory)

    local url=$1
    local rev=$2
    local base=$(basename $1)

    pushd $sdir &>/dev/null
        # Does the url look like "git+https://"?
        if [[ "$url" =~ ^git\+.* ]]; then
            # Extract the real URL portion of the string
            url="$(expr match "$url" '.*+\(.*\)')"

            # A lot of git repository URLs end with ".git". However, the basename of the URL
            # becomes the local source directory. When the basename ends with .git, just
            # strip it off (i.e. repo.git -> repo).
            if [[ $base == *.git ]]; then
                base="$(expr match "$base" '\(.*\).git*')"
            fi

            # Don't do a clone if we already have one
            [[ ! -d $base ]] && git clone --recursive "$url" "$base"

            # If we don't specify a revision, then default to the master branch
            if [[ -z $rev ]]; then
                rev="master"
            fi

            pushd $base &>/dev/null
                # Always fetch new objects and tags (useful when reusing cloned repos)
                git fetch &>/dev/null
                git fetch --tags &>/dev/null

                # Move HEAD
                git checkout "$rev" &>/dev/null

                # Populate package naming variables
                local gitver="$(git rev-list --count HEAD).$(git rev-parse --short  HEAD)"
                local pkg="${base}-r${gitver}"

                # Instead of building straight from our clone, we generate a tarball based on
                # the latest commit. No it isn't hacky damnit, it's smart. You cannot guarantee anything
                # will be the same tomorrow, so this add a bit of insurance and accountability.
                #
                # Note: "git checkout [rev]" moves HEAD to that revision. This is perfectly safe.
                #
                #       YOU ONLY MOVED THE HEADSTONES! WHY?! WHY?!
                #                           -- Craig T. Nelson
                #

                if [[ ! -f $sdir/${pkg}.tar.gz ]]; then
                    echo "GENERATING TARBALL: ${pkg}.tar.gz"
                    git archive --format tgz --prefix="${pkg}/" -o "$sdir/${pkg}.tar.gz" HEAD
                fi
            popd &>/dev/null

        # Generic downloader is generic
        elif [[ ! -f $base ]] && [[ ! -d $base ]]; then
            echo "Fetching: $base..."
            curl -LO "$url"
        fi

    # failsafe popd for $sdir
    popd &>/dev/null
}

function build_start {
    local name=$1
    local version=$2
    local delim=$3
    local archive=

    if [[ -z $delim ]]; then delim='-'; fi

    # We make assumptions about the innards of the archive. Most of the time we're correct.
    # When things don't match up you might need to repackage things manually.
    export pkgdir=${name}${delim}${version}
    export lock_file="${ldir}/${pkgdir}"

    # Don't rebuild packages automatically.
    if [[ -f ${lock_file} ]]; then
        echo "Skipped $pkgdir (remove $lock_file to rebuild)"
        export skipped=1
        export build_no_popd=1
        return 0
    fi

    # Perform a cheap scan for the archive
    archive=$(find $sdir -type f \
        \( -name "${pkgdir}.tar*" \
        -o -name "${pkgdir}.t*z" \
        -o -name "${pkgdir}.t*2" \
        -o -name "${pkgdir}.zip" \) | head -n 1)

    if [[ ! -f $archive ]]; then
        echo "$pkgdir has no archive. Dying."
        exit 1
    fi

    # Extract by archive type
    case "$archive" in
        *.tar.bz2|*.tbz2|*.tgz|*.tar.gz|*.txz|*.tar.xz)
            tar xf "$archive" || exit 2
            ;;
        *.zip)
            unzip "$archive" || exit 2
            ;;
        *)
            echo "$pkgdir ($archive): unsupported archive"
            exit 1
            ;;
    esac


    # The entire script will fail out on its own shortly after the WARNING is issued
    if [[ -d $pkgdir ]]; then
        cd "$pkgdir"
    else
        echo "WARNING: $pkgdir is not a real directory. Adjust build script to compensate."
    fi

    # Generate a lock file for this build
    touch "${lock_file}"

    echo $ruler
    echo "BUILDING: ${name}"
    echo $ruler
}

function build_end {
    export pkgdir=''
    export lock_file=''
    export skipped=0
    export build_no_popd=0
    cd "$bdir"
}


#
# BUILD START HERE
#
pushd $bdir

fetch "https://ftp.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz"
build_start autoconf 2.69
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/m4/m4-1.4.18.tar.gz"
build_start m4 1.4.18
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/libtool/libtool-2.4.6.tar.gz"
build_start libtool 2.4.6
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/libiconv/libiconv-1.15.tar.gz"
build_start libiconv 1.15
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/ncurses/ncurses-6.0.tar.gz"
build_start ncurses 6.0
if (( ! skipped )); then
    ./configure --prefix=$PREFIX --with-shared
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/readline/readline-7.0.tar.gz"
build_start readline 7.0
if (( ! skipped )); then
    ./configure --prefix=$PREFIX CFLAGS="$CFLAGS -fPIC"
    make -j${CPU_COUNT} SHLIB_LIBS=-lncurses
    make install
fi
build_end

fetch "https://tukaani.org/xz/xz-5.2.3.tar.gz"
build_start xz 5.2.3
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "ftp://xmlsoft.org/libxml2/libxml2-2.9.7.tar.gz"
build_start libxml2 2.9.7
if (( ! skipped )); then
    ./configure --prefix=$PREFIX --without-python
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/gettext/gettext-0.19.8.1.tar.gz"
build_start gettext 0.19.8.1
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/automake/automake-1.15.1.tar.gz"
build_start automake 1.15.1
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://pkg-config.freedesktop.org/releases/pkg-config-0.29.1.tar.gz"
build_start pkg-config 0.29.1
if (( ! skipped )); then
    ./configure --prefix=$PREFIX --with-internal-glib
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://zlib.net/zlib-1.2.11.tar.gz"
build_start zlib 1.2.11
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install

fi
build_end

fetch "http://www.bzip.org/1.0.6/bzip2-1.0.6.tar.gz"
fetch "$patch_url/bzip2-Makefile.patch"
fetch "$patch_url/bzip2-Makefile-shared.patch"
build_start bzip2 1.0.6
if (( ! skipped )); then
    patch -Np0 < $sdir/bzip2-Makefile.patch
    patch -Np0 < $sdir/bzip2-Makefile-shared.patch

    make -j${CPU_COUNT} -f Makefile-libbz2_so PREFIX=$PREFIX
    make install PREFIX=$PREFIX
fi
build_end

#
# GNU only
# Required by pacman/pkgbuild/makepkg
#
fetch "https://ftp.gnu.org/gnu/coreutils/coreutils-8.28.tar.xz"
build_start coreutils 8.28
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
   make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/findutils/findutils-4.6.0.tar.gz"
build_start findutils 4.6.0
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
   make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/sed/sed-4.4.tar.xz"
build_start "sed" 4.4
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
   make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/gawk/gawk-4.2.0.tar.gz"
build_start "gawk" 4.2.0
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
   make install
fi
build_end

fetch "https://www.libarchive.org/downloads/libarchive-3.3.2.tar.gz"
build_start libarchive 3.3.2
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/bash/bash-4.4.12.tar.gz"
build_start bash 4.4.12
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

# OpenSSL has issues...
build_no_popd=1
fetch "https://www.openssl.org/source/openssl-1.1.0g.tar.gz"
build_start openssl "1.1.0g"
if (( ! skipped )); then
    ./config --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
    if [[ $(uname -s) == Darwin ]]; then
        security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain \
            > $PREFIX/ssl/cert.pem
    else
        cp $sdir/cacert.pem $PREFIX/ssl/cert.pem
    fi
fi
build_end

fetch "https://curl.haxx.se/download/curl-7.57.0.tar.gz"
build_start curl 7.57.0
if (( ! skipped )); then
    cadir=$PREFIX/etc/certificates
    cadir_datadir=$PREFIX/share/ca-certificates
    mkdir -p $cadir
    mkdir -p $cadir_datadir

    cp -a $sdir/cacert.pem $cadir

    ./configure --prefix=$PREFIX --with-ca-bundle=$cadir/cacert.pem --with-ca-path=$cadir_datadir
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "git+https://github.com/jhunkeler/fakeroot" "fix-wrapfunc"
build_start fakeroot "r514.dab5ec4"
if (( ! skipped )); then
    ./bootstrap
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

#
# Started with this custom version, but eventually patched out the failures in the real one.
#
#fetch "git+https://github.com/duskwuff/darwin-fakeroot" "v1.1"
#fetch "$patch_url/darwin-fakeroot.patch"
#build_start darwin-fakeroot r6.e6963fb
#if (( ! skipped )); then
#    patch -Np0 < $sdir/darwin-fakeroot.patch
#    make
#    make PREFIX=$PREFIX install
#fi
#build_end

fetch "git+https://git.archlinux.org/pacman.git" "e4f13e62cf74393e811dd247a28b887935ce6a56"
fetch "$patch_url/pacman-rootless.patch"
fetch "$patch_url/pacman-osx-msg_nosignal.patch"
fetch "$patch_url/pacman-config-normalize.patch"
fetch "$patch_url/pacman-makepkg-config-normalize.patch"
build_start pacman r6429.e4f13e6
if (( ! skipped )); then
    patch -Np1 < $sdir/pacman-rootless.patch

    if [[ $(uname -s) == Darwin ]]; then
        patch -Np1 < $sdir/pacman-osx-msg_nosignal.patch
        patch -Np0 < $sdir/pacman-config-normalize.patch
        patch -Np0 < $sdir/pacman-makepkg-config-normalize.patch
        #patch -Np1 < $sdir/pacman-osx-fakerootkey.patch
    fi

    ./autogen.sh
    ./configure --prefix=$PREFIX \
        --disable-doc \
        --with-libcurl \
        --with-scriptlet-shell=$PREFIX/bin/bash \
        --with-root-dir=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "ftp://sourceware.org/pub/libffi/libffi-3.2.1.tar.gz"
build_start libffi 3.2.1
if (( ! skipped )); then
    ./configure --prefix=$PREFIX
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://ftp.gnu.org/gnu/gdbm/gdbm-1.14.1.tar.gz"
build_start gdbm 1.14.1
if (( ! skipped )); then
    ./configure --prefix=$PREFIX --enable-libgdbm-compat
    make -j${CPU_COUNT}
    make install
fi
build_end

fetch "https://www.python.org/ftp/python/3.6.4/Python-3.6.4.tgz"
build_start Python 3.6.4
if (( ! skipped )); then
    ./configure --prefix=$PREFIX --enable-ipv6 --with-system-ffi --with-threads --with-pydebug --with-ensurepip
    make -j${CPU_COUNT}
    make install
    pushd $PREFIX/bin
        ln -sf python3.6 python
        ln -sf pip3.6 pip
    popd
    pip install --upgrade --force setuptools
    pip install --upgrade --force pip
fi
build_end

fetch "git+https://git.archlinux.org/pyalpm.git" "0.8.2"
build_start pyalpm r308.6f0787e
if (( ! skipped )); then
    sed -i -e 's|-Werror||g' setup.py
    python setup.py install
fi
build_end

# keep this
popd # -- exits $bdir
exit 0

