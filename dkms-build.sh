#!/bin/bash -eux

# configuration

NAME=snaptv-dddvb
sub_repo=dddvb
build_command="make -j4"
no_option_cmds="ifpeErdxR"

[ $# -ne 0 ] && cmds=$1 || cmds=$no_option_cmds

KERNEL_RUNNING=$(uname -r)
KERNEL_VERSION=3.13.0-61-lowlatency
KERNEL_ARCH=x86_64
TOOL_BRANCH=master
[[ $cmds =~ K ]] && KERNEL_VERSION=$(uname -r)

helptext='

Script that produces the debian package of the drivers (dkms-binary-style)
Arguments:
  No option: assume virtual env, do everything
  h: "help"
  i: "install" Prepare for build by installing required packages
  f: "fetch" Fetch clean version of sources (submodule repo)
  p: "Patch sources so they are prepared for compilation"
  m: "modules" Use to generate the file named "modules".
     Makes a list of all modules the driver consists of.
     (The file "modules" normally contains a sub-set of these modules.)
  r: "build - rebuild"
  e: Turn off error return check during build
  E: No error check at all
  d: "Generate debian packet"
  x: "Clean up after build"
  z: "Install" install the debian package

  v: "View info about (alien) dkms sources and modules"
  K: Build for the build environment currently installed kernel
  R: Ensure installed kernel is the kernel version this dkms module will be built for

Examples:
  sudo ./dkms-build.sh Ki        (to install the build tools (current kernel))
  sudo ./dkms-build.sh KfpeErdx  (to build the package for current kernel)

'
[[ $cmds =~ h ]] && exit

function leave {
    exit 1
}

[ "$EUID" -ne 0 ] && leave "Please run as root"

if [[ $cmds =~ R ]]; then
    [ "$KERNEL_VERSION" == "$KERNEL_RUNNING" ] || leave 'This dkms build will fail due to wrong installed kernel'
fi

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
    curl http://apt.snap.tv/bootstrap.sh | sh -s $TOOL_BRANCH
    apt-get update
    apt-get install -y \
            snaptv-package-builder
fi

if [[ $cmds =~ f ]]; then
    [ -e $sub_repo ] && rm -r $sub_repo
    git submodule update --init
fi

LONGVER=$(snap-make-changelog -c | head -1)

pushd $sub_repo

HASH=$(git describe --tag --always HEAD)
VERSION=$(echo $HASH | sed 's/-g.......$//')

KERNEL_VERSION_ARCH=$KERNEL_VERSION/$KERNEL_ARCH
FULL_VERSION=$VERSION-snaptv-$LONGVER
ID=$NAME/$FULL_VERSION
LIB_DIR=/var/lib/dkms/$ID
SRC_DIR=/usr/src/$NAME-$FULL_VERSION

if [[ $cmds =~ p ]]; then
    for file in $(find ../patches -type f | sort) ; do
        patch -p1 <$file
    done
fi

[ -e ../modules ] && modules=$(cat ../modules) || modules='unknown'

if [[ $cmds =~ m ]]; then
    [[ $cmds =~ e ]] && set +e
    $build_command
    set -e
    modules=$(find -name *.ko | awk -F/ '{print $NF}' | cut -d. -f1 | sort)
fi

if [[ $cmds =~ r ]]; then

    [ -e $SRC_DIR ] && leave "Unexpected folder $SRC_DIR, will not build"
    [ -e $LIB_DIR ] && leave "Unexpected folder $LIB_DIR, will not build"

    rsync -uav --exclude=.git ./ $SRC_DIR >/dev/null

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

    mv dkms.conf $SRC_DIR

    # copy template
    sudo rsync -uav /etc/dkms/template-dkms-mkdeb/ $SRC_DIR/$NAME-dkms-mkdeb/

    # manipulate postinst, dkms install to the correct kernel
    sed s/\\tdkms_configure/"\
\\tdkms ldtarball \/usr\/share\/$NAME-dkms\/$NAME-$FULL_VERSION.dkms.tar.gz\\n\
\\tdkms install -m $NAME -v $FULL_VERSION -k $KERNEL_VERSION\
"/ <$SRC_DIR/$NAME-dkms-mkdeb/debian/postinst >postinst
    # manipulate control, set dependent of kernel
    sed s/Depends:/"Depends: linux-headers-$KERNEL_VERSION, linux-image-$KERNEL_VERSION,"/ <$SRC_DIR/$NAME-dkms-mkdeb/debian/control >control
    chmod 755 postinst
    mv control postinst $SRC_DIR/$NAME-dkms-mkdeb/debian/

    [[ $cmds =~ e ]] && set +e
    dkms build $ID -k $KERNEL_VERSION_ARCH
    DKMS_RET=$?
    [[ $cmds =~ E ]] && DKMS_RET=0
    set -e
    LOGS=$(find $LIB_DIR -type f | egrep '\.log$')
    if [ "$LOGS" ] ; then
        cat $LOGS
    fi
    [ "$DKMS_RET" -ne 0 ] && leave 'Compiler errors'

    mkdir -p $LIB_DIR/$KERNEL_VERSION_ARCH/module
    for MODULE in $(find $LIB_DIR -type f | egrep '\.ko$'); do
        [ "$(dirname $MODULE)" == "$LIB_DIR/$KERNEL_VERSION_ARCH/module" ] || mv $MODULE $LIB_DIR/$KERNEL_VERSION_ARCH/module
    done
    dkms mkdeb $ID -k $KERNEL_VERSION_ARCH --binaries-only

fi

popd

if [[ $cmds =~ d ]]; then

    DEB=$(find $LIB_DIR/deb/ -type f)
    echo $DEB
    debian_file=$(basename $DEB)

    # put the dkms.conf file into the debian packet

    mkdir -p ~/"$HASH"/x/DEBIAN
    pushd ~/"$HASH"
    dpkg -x $DEB x
    dpkg -e $DEB x/DEBIAN
    mkdir -p x$SRC_DIR
    cp $SRC_DIR/dkms.conf x$SRC_DIR
    dpkg -b x ~

    popd
fi

if [[ $cmds =~ x ]]; then
    dkms remove $ID -k $KERNEL_VERSION
    rm -fr $SRC_DIR
    rm -fr ~/"$HASH"
fi

if [[ $cmds =~ z ]]; then
    if [ -e ~/$debian_file ]; then
        dpkg -i ~/$debian_file
    else
        t='No such file'
    fi
fi

[[ $cmds =~ v ]] && ls -l /usr/src/* /var/lib/dkms/*/* | cut -d : -f1 | grep \^/ | grep ~g || echo "Done"
