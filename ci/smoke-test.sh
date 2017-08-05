#!/bin/bash -ex


clone_build()
{
    REPOS=("on-http" "on-taskgraph" "on-dhcp-proxy" "on-tftp" "on-syslog")

    echo "[Info]Clone source code done, start to npm install...."
    local pid_arr=()
    local cnt=0
    pushd $1
    #### NPM Install Parallel ######
    for i in ${REPOS[@]}; do
        git clone https://github.com/rackhd/${i}.git
        pushd ${i}
        echo "[${i}]: running :  npm install --production"
        npm install --production &
        # run in background, save its PID into pid_array
        pid_arr[$cnt]=$!
        cnt=$(( $cnt + 1 ))
        popd
    done

    ## Wait for background npm install to finish ###
    for index in $(seq 0 $(( ${#pid_arr[*]} -1 ))  );
    do
        wait ${pid_arr[$index]} # Wait for background running 'npm install' process
        echo "[${REPOS[$index]}]: finished :  npm install"
        if [ "$?" != "0" ] ; then
            echo "[Error] npm install failed for repo:" ${REPOS[$index]} ", Abort !"
            exit 3
        fi
    done
    popd

}

wget_download(){

  argv=($@)
  argc=$#
  retry_time=5
  remote_file=${argv[$(($argc -1 ))]} # not accurate enough..
  echo "[Info] Downloading ${remote_file}"

  # -c  resume getting a partially-downloaded file.
  # -nv reduce the verbose output
  # -t 5  the retry counter
  wget -c -t ${retry_time} -nv $@  # $@ means all function arguments from $1 to $n

  if [ $? -ne 0 ]; then
     echo "[Error]: wget download failed: ${remote_file}"
     exit 2
 else
     echo "[Info] wget download successfully ${remote_file}"
  fi

}


dlHttpFiles() {
  dir=$1/on-http/static/http/common
  mkdir -p ${dir}
  pushd ${dir}
  if [ -n "${INTERNAL_HTTP_ZIP_FILE_URL}" ]; then
    # use INTERNAL TEMP SOURCE
    wget_download ${INTERNAL_HTTP_ZIP_FILE_URL}

    unzip common.zip && mv common/* . && rm -rf common
  else
    # pull down index from bintray repo and parse files from index
    wget_download --no-check-certificate https://dl.bintray.com/rackhd/binary/builds/ && \
        exec  cat index.html |grep -o href=.*\"|sed 's/href=//' | sed 's/"//g' > files
    for i in `cat ./files`; do
      wget_download --no-check-certificate https://dl.bintray.com/rackhd/binary/builds/${i}
    done
    # attempt to pull down user specified static files
    for i in ${HTTP_STATIC_FILES}; do
      wget_download --no-check-certificate https://bintray.com/artifact/download/rackhd/binary/builds/${i}
    done
  fi
  popd
}

dlTftpFiles() {
  dir=$1/on-tftp/static/tftp
  mkdir -p ${dir}
  pushd ${dir}
  if [ -n "${INTERNAL_TFTP_ZIP_FILE_URL}" ]; then
    # use INTERNAL TEMP SOURCE
    wget_download ${INTERNAL_TFTP_ZIP_FILE_URL}
    unzip pxe.zip && mv pxe/* . && rm -rf pxe pxe.zip
  else
    # pull down index from bintray repo and parse files from index
    wget_download --no-check-certificate https://dl.bintray.com/rackhd/binary/ipxe/ && \
        exec  cat index.html |grep -o href=.*\"|sed 's/href=//' | sed 's/"//g' > files
    for i in `cat ./files`; do
      wget_download --no-check-certificate https://dl.bintray.com/rackhd/binary/ipxe/${i}
    done
    # attempt to pull down user specified static files
    for i in ${TFTP_STATIC_FILES}; do
      wget_download --no-check-certificate https://bintray.com/artifact/download/rackhd/binary/ipxe/${i}
    done
  fi
  popd
}

waitForAPI() {
  netstat -ntlp
  timeout=0
  maxto=60
  set +e
  url=http://localhost:9090/api/2.0/nodes
  while [ ${timeout} != ${maxto} ]; do
    wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 1 --continue ${url}
    if [ $? = 0 ]; then
      break
    fi
    sleep 10
    timeout=`expr ${timeout} + 1`
  done
  set -e
  if [ ${timeout} == ${maxto} ]; then
    echo "Timed out waiting for RackHD API service (duration=`expr $maxto \* 10`s)."
    exit 1
  fi
}


WORKSPACE=$1
RackHD_Folder=$2
pwd
whoami
ls $WORKSPACE
find $RackHD_Folder/ci

apt-get update \
&&   apt-get install -y git \
&&   apt-get install -y bridge-utils \
&&   apt-get install -y libnuma-dev \
&&   apt-get install -y python-pip libpython-dev libssl-dev \
&&   sudo pip install --upgrade pip \
&&   sudo pip install setuptools  \
&&   sudo pip install infrasim-compute

apt-get install -y unzip  #swagger ui

pip install virtualenv

mkdir -p /opt/monorail
cp  ${WORKSPACE}/monorail/* /opt/monorail/

mkdir -p ${WORKSPACE}/src
cp ${WORKSPACE}/rackhd.yml ${WORKSPACE}/src
clone_build ${WORKSPACE}/src
dlHttpFiles ${WORKSPACE}/src
dlTftpFiles ${WORKSPACE}/src

# config InfraSIM
infrasim init
infrasim node destroy
pwd
ls ${WORKSPACE}
cp ${WORKSPACE}/infrasim_config.yml  ~/.infrasim/.node_map/default.yml

#######################

rm -f /var/lib/dhcp/dhchp.leases
touch /var/lib/dhcp/dhcpd.leases
chown root:root /var/lib/dhcp/dhcpd.leases
chmod 666 /var/lib/dhcp/dhcpd.leases

service isc-dhcp-server stop


# Set up br0
brctl addbr br0
ifconfig br0 promisc
ifconfig br0 172.31.128.1


service mongodb start
sleep 1
service rabbitmq-server start
sleep 1

service isc-dhcp-server start

pm2 status
pm2 logs > /var/log/rackhd.log &
pushd ${WORKSPACE}/src
pm2 start rackhd.yml
sleep 15 && infrasim node start &
dhcpd -f -cf /etc/dhcp/dhcpd.conf -lf /var/lib/dhcp/dhcpd.leases --no-pid &
popd

waitForAPI

pushd ${RackHD_Folder}/test
rm -rf .venv/on-build-config
./mkenv.sh on-build-config
source myenv_on-build-config
python run_tests.py -test deploy/rackhd_stack_init.py -stack docker_local_run -numvms 1 -rackhd_host localhost -port 9090 -xunit -v 9
python run_tests.py -test tests -group smoke -stack docker_local_run -numvms 1 -rackhd_host localhost -port 9090 -xunit -v 9
deactive
popd


