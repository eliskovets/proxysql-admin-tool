#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# The script is used for testing proxysql-admin functionality

# User Configurable Variables
if [ -z $1 ]; then
  echo "No valid parameters were passed. Need relative workdir setting. Retry.";
  echo "Usage example:"
  echo "$./proxysql-admin-testsuite.sh /sda/proxysql-testing"
  exit 1
else
  WORKDIR=$1
fi

if [[ ! -e $(which mysql 2> /dev/null) ]] ;then
  echo "ERROR! 'mysql' is currently not installed. Please install mysql. Terminating!"
  exit 1
fi
  
SBENCH="sysbench"
SCRIPT_PWD=$(cd `dirname $0` && pwd)
PXC_START_TIMEOUT=200
SUSER=root
SPASS=
OS_USER=$(whoami)

if [ -z $WORKDIR ];then
  WORKDIR="${PWD}"
fi
ROOT_FS=$WORKDIR

mkdir -p $WORKDIR/logs

ps -ef | egrep "mysqld" | grep "$(whoami)" | egrep -v "grep" | xargs kill -9 2>/dev/null
ps -ef | egrep "node..sock" | grep "$(whoami)" | egrep -v "grep" | xargs kill -9 2>/dev/null

cd ${WORKDIR}

echo "Removing existing basedir"
find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.*' -exec rm -rf {} \+

#Check PXC binary tar ball
PXC_TAR=$(ls -1td ?ercona-?tra??-?luster* | grep ".tar" | head -n1)
if [ ! -z $PXC_TAR ];then
  tar -xzf $PXC_TAR
  PXCBASE=$(ls -1td ?ercona-?tra??-?luster* | grep -v ".tar" | head -n1)
  export PATH="$WORKDIR/$PXCBASE/bin:$PATH"
  export PXC_BASEDIR="${WORKDIR}/$PXCBASE"
else
  echo "ERROR! Percona-XtraDB-Cluster binary tarball does not exist. Terminating"
  exit 1
fi

PROXYSQL_BASE=$(ls -1td proxysql-1* | grep -v ".tar" | head -n1)
export PATH="$WORKDIR/$PXCBASE/usr/bin/:$PATH"
PROXYSQL_BASE="${WORKDIR}/$PROXYSQL_BASE"
rm -rf $WORKDIR/proxysql_db; mkdir $WORKDIR/proxysql_db
$PROXYSQL_BASE/usr/bin/proxysql -D $WORKDIR/proxysql_db  $WORKDIR/proxysql_db/proxysql.log &

if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
elif [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${PXC_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXC_BASEDIR}"
fi


start_pxc_node(){
  CLUSTER_NAME=$1
  NODES=3
  RPORT=$(( RANDOM%21 + 10 ))
  RBASE="$(( RPORT*1000 ))"
  ADDR="127.0.0.1"
  WSREP_CLUSTER_NAME="--wsrep_cluster_name=$CLUSTER_NAME"
  # Creating default my.cnf file
  cd $PXC_BASEDIR
  echo "[mysqld]" > my.cnf
  echo "basedir=${PXC_BASEDIR}" >> my.cnf
  echo "innodb_file_per_table" >> my.cnf
  echo "innodb_autoinc_lock_mode=2" >> my.cnf
  echo "innodb_locks_unsafe_for_binlog=1" >> my.cnf
  echo "wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so" >> my.cnf
  echo "wsrep_node_incoming_address=$ADDR" >> my.cnf
  echo "wsrep_sst_method=rsync" >> my.cnf
  echo "wsrep_sst_auth=$SUSER:$SPASS" >> my.cnf
  echo "wsrep_node_address=$ADDR" >> my.cnf
  echo "core-file" >> my.cnf
  echo "log-output=none" >> my.cnf
  echo "server-id=1" >> my.cnf
  echo "wsrep_slave_threads=2" >> my.cnf

  for i in `seq 1 $NODES`;do
    RBASE1="$(( RBASE + ( 100 * $i ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
    node="${PXC_BASEDIR}/${CLUSTER_NAME}${i}"
    if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
      mkdir -p $node $keyring_node
      if  [ ! "$(ls -A $node)" ]; then
        ${MID} --datadir=$node  > $WORKDIR/logs/startup_node${CLUSTER_NAME}${i}.err 2>&1 || exit 1;
      fi
    fi
    if [ ! -d $node ]; then
      ${MID} --datadir=$node  > $WORKDIR/logs/startup_node${CLUSTER_NAME}${i}.err 2>&1 || exit 1;
    fi
    if [ $i -eq 1 ]; then
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
          BASEPORT=$RBASE1
    else
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
    fi

    ${PXC_BASEDIR}/bin/mysqld --defaults-file=${PXC_BASEDIR}/my.cnf \
      --datadir=$node $WSREP_CLUSTER_ADD  \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
      --log-error=$WORKDIR/logs/${CLUSTER_NAME}${i}.err \
      --socket=/tmp/${CLUSTER_NAME}${i}.sock --port=$RBASE1 $WSREP_CLUSTER_NAME > $WORKDIR/logs/${CLUSTER_NAME}${i}.err 2>&1 &
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/${CLUSTER_NAME}${i}.sock ping > /dev/null 2>&1; then
        echo "Started PXC ${CLUSTER_NAME}${i}. Socket : /tmp/${CLUSTER_NAME}${i}.sock"
        break
      fi
    done
  done
}

start_pxc_node cluster_one
WSREP_CLUSTER=""
NODES=0
start_pxc_node cluster_two

${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock -e"GRANT ALL ON *.* TO admin@'%' identified by 'admin';flush privileges;"
${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock -e"GRANT ALL ON *.* TO admin@'%' identified by 'admin';flush privileges;"
sudo cp $PROXYSQL_BASE/etc/proxysql-admin.cnf /etc/proxysql-admin.cnf
sudo chown $OS_USER:$OS_USER /etc/proxysql-admin.cnf
sudo sed -i "s|\/var\/lib\/proxysql|$PROXYSQL_BASE|" /etc/proxysql-admin.cnf
sudo cp $PROXYSQL_BASE/usr/bin/* /usr/bin/

if [[ ! -e $(sudo which bats 2> /dev/null) ]] ;then
  pushd $ROOT_FS
  git clone https://github.com/sstephenson/bats
  cd bats
  sudo ./install.sh /usr
  popd
fi

echo "proxysql-admin generic bats test log"
sudo TERM=xterm bats $SCRIPT_PWD/generic-test.bats

echo "proxysql-admin testsuite bats test log for custer_one"
CLUSTER_ONE_PORT=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock -Bse"select @@port")
sudo sed -i "0,/^[ \t]*export CLUSTER_PORT[ \t]*=.*$/s|^[ \t]*export CLUSTER_PORT[ \t]*=.*$|export CLUSTER_PORT=\"$CLUSTER_ONE_PORT\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$|export CLUSTER_APP_USERNAME=\"cluster_one\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export WRITE_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export WRITE_HOSTGROUP_ID[ \t]*=.*$|export WRITE_HOSTGROUP_ID=\"10\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export READ_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export READ_HOSTGROUP_ID[ \t]*=.*$|export READ_HOSTGROUP_ID=\"11\"|" /etc/proxysql-admin.cnf
sudo TERM=xterm bats $SCRIPT_PWD/proxysql-admin-testsuite.bats

echo "proxysql-admin testsuite bats test log for custer_two"
CLUSTER_TWO_PORT=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock -Bse"select @@port")
sudo sed -i "0,/^[ \t]*export CLUSTER_PORT[ \t]*=.*$/s|^[ \t]*export CLUSTER_PORT[ \t]*=.*$|export CLUSTER_PORT=\"$CLUSTER_TWO_PORT\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$|export CLUSTER_APP_USERNAME=\"cluster_two\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export WRITE_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export WRITE_HOSTGROUP_ID[ \t]*=.*$|export WRITE_HOSTGROUP_ID=\"20\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export READ_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export READ_HOSTGROUP_ID[ \t]*=.*$|export READ_HOSTGROUP_ID=\"21\"|" /etc/proxysql-admin.cnf
sudo TERM=xterm bats $SCRIPT_PWD/proxysql-admin-testsuite.bats

${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_one1.sock  -u root shutdown
${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_one2.sock  -u root shutdown
${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_one3.sock  -u root shutdown
${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_two1.sock  -u root shutdown
${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_two2.sock  -u root shutdown
${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_two3.sock  -u root shutdown