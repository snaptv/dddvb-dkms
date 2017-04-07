#!/bin/bash -eux

# configuration

NAME=snaptv-analog
no_option_cmds="ifprdx"
KERNEL_VERSION=3.13.0-61-lowlatency
KERNEL_ARCH=x86_64
build_command="make -j4"

[ $# -ne 0 ] && cmds=$1 || cmds=$no_option_cmds
helptext='

Script that produces the debian package of the drivers (dkms-binary-style)
Arguments:
  No option: assume virtual env, do everything
  h: "help"
  P: "Probe" (git) generate a temp branch and probe every step by committing
  i: "install" Prepare for build by installing required packages
  c: clean
  f: "Fetch git commit pointed to by source-version
  p: "Patch sources so they are prepared for compilation"
  r: "build - rebuild"
  m: "modules" Needed if there is no file named "modules",
     Makes a list of all modules the driver consists of. (The file "modules"
     normally contains a sub-set of these modules.)
  d: "Generate debian packet"
  x: "Clean up after build"
  z: "Install" install the debian package
  
  v: "View info about dkms sources and modules"

  icfprdxz: Any combination of these command letters might be used

Example:
  sudo ./dkms-build.sh fprdx

'
[[ $cmds =~ h ]] && exit

function leave {
    exit
}

[ "$EUID" -ne 0 ] && leave "Please run as root"

HASH=$(git describe --tag --always $source_version)
LONGVER=$(snap-make-changelog -c | head -1)
VERSION=$(echo $HASH | sed 's/-g.......$//')

curr_branch=$(git branch | grep \* | cut -d ' ' -f2)

[ "$curr_branch" == "temp" ] && leave "Branch named temp is reserved for debug"

function probe {
    git add --all
    git commit --allow-empty -m "$1"
}
function prepare_probing {
    [ "$(git branch | egrep "^[ ]*temp-old$")" ] && git branch -D temp-old
    [ "$(git branch | egrep "^[ ]*temp$")" ] && git branch -m temp temp-old
    git branch temp
    git checkout temp
    probe "Probing starts, cmds = $cmds" 
}
function end_probing {
    git checkout $curr_branch
}
function do_clean {
    git clean -f
    git clean -fd
    git clean -fX
    git reset --hard
    git checkout .
}

[[ $cmds =~ c ]] && do_clean
[[ $cmds =~ P ]] && prepare_probing

if [[ $cmds =~ i ]]; then
    apt-get update
    apt-get install -y \
            bzip2 \
            debhelper \
            dkms \
            dpkg-dev \
            git \
            libproc-processtable-perl \
            linux-headers-$KERNEL_VERSION \
            wget \
            curl
    curl http://apt.snap.tv/bootstrap.sh | sh -s master
    apt-get update
    apt-get install -y \
            snaptv-package-builder
fi

KERNEL_VERSION_ARCH=$KERNEL_VERSION/$KERNEL_ARCH
FULL_VERSION=$VERSION-snaptv-$LONGVER
ID=$NAME/$FULL_VERSION
LIB_DIR=/var/lib/dkms/$ID

if [[ $cmds =~ f ]]; then
    git checkout $source_version -- .
    git reset
    [[ $cmds =~ P ]] && probe "f - Fetched source"
fi


if [[ $cmds =~ p ]]; then
    for file in $(find patches -type f | sort) ; do
        patch -p1 <$file
    done
    [[ $cmds =~ P ]] && probe "p - Patched source"
fi


if [[ $cmds =~ m ]]; then
    $build_command
    modules=$(find -name *.ko | awk -F/ '{print $NF}' | cut -d. -f1 | sort)
fi

if [[ $cmds =~ r ]]; then

    rsync -uav --exclude=.git ./ /usr/src/$NAME-$FULL_VERSION >/dev/null
    if [ -e modules ]; then
        modules=$(cat modules)
    else
        $build_command
        modules=$(find -name *.ko | awk -F/ '{print $NF}' | cut -d. -f1 | sort)
    fi

    echo "
PACKAGE_NAME=$NAME
PACKAGE_VERSION=$FULL_VERSION
AUTOINSTALL=y
MAKE[0]='$build_command'
BUILD_EXCLUSIVE_KERNEL='^$KERNEL_VERSION'" > dkms.conf
    num=0
    for module in $modules; do
        echo BUILT_MODULE_NAME["$num"]="$module" >> dkms.conf
        echo BUILT_MODULE_LOCATION["$num"]=./v4l >> dkms.conf
        echo DEST_MODULE_LOCATION["$num"]=/updates/dkms >> dkms.conf
        num=$((num+1))
    done

    mv dkms.conf /usr/src/$NAME-$FULL_VERSION

    # copy template
    sudo rsync -uav /etc/dkms/template-dkms-mkdeb/ /usr/src/$NAME-$FULL_VERSION/$NAME-dkms-mkdeb/

    # manipulate postinst, dkms install to the correct kernel
    sed s/\\tdkms_configure/"\
\\tdkms ldtarball \/usr\/share\/$NAME-dkms\/$NAME-$FULL_VERSION.dkms.tar.gz\\n\
\\tdkms install -m $NAME -v $FULL_VERSION -k $KERNEL_VERSION\
"/ </usr/src/$NAME-$FULL_VERSION/$NAME-dkms-mkdeb/debian/postinst >postinst
    # manipulate control, set dependent of kernel
    sed s/Depends:/"Depends: linux-headers-$KERNEL_VERSION, linux-image-$KERNEL_VERSION,"/ </usr/src/$NAME-$FULL_VERSION/$NAME-dkms-mkdeb/debian/control >control
    chmod 755 postinst
    mv control postinst /usr/src/$NAME-$FULL_VERSION/$NAME-dkms-mkdeb/debian/

    set +e
    dkms build $ID -k $KERNEL_VERSION_ARCH
    set -e

    mkdir -p $LIB_DIR/$KERNEL_VERSION_ARCH/module
    for MODULE in $(find $LIB_DIR -type f | egrep '\.ko$'); do
        mv $MODULE $LIB_DIR/$KERNEL_VERSION_ARCH/module
    done
    dkms mkdeb $ID -k $KERNEL_VERSION_ARCH --binaries-only

fi

if [[ $cmds =~ d ]]; then

    DEB=$(find $LIB_DIR/deb/ -type f)
    echo $DEB
    debian_file=$(basename $DEB)

    # put the dkms.conf file into the debian packet

    mkdir -p ~/"$HASH"/x/DEBIAN
    pushd ~/"$HASH"
    dpkg -x $DEB x
    dpkg -e $DEB x/DEBIAN
    mkdir -p x/usr/src/"$NAME"-"$FULL_VERSION"
    cp /usr/src/"$NAME"-"$FULL_VERSION"/dkms.conf x/usr/src/"$NAME"-"$FULL_VERSION"
    dpkg -b x ~

    popd
fi

if [[ $cmds =~ x ]]; then
    dkms remove $ID -k $KERNEL_VERSION
    rm -fr /usr/src/"$NAME"-"$FULL_VERSION"
    rm -fr ~/"$HASH"
    do_clean
fi

if [[ $cmds =~ z ]]; then
    if [ -e ~/$debian_file ]; then
        dpkg -i ~/$debian_file
    else
        t='No such file'
    fi
fi

[[ $cmds =~ v ]] && ls -l /usr/src/* /var/lib/dkms/*/* | cut -d : -f1 | grep \^/ | grep ~g
[[ $cmds =~ P ]] && end_probing
