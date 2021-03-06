#!/bin/bash

usage() {
    echo "usage: $PROG [-C file ] args"
    echo "       -C file                                   Use alternate file for vagrantconfig.yaml"
    echo "  commands:"
    echo "       -b, --build-image                         Build base Docker image for Bigtop Hadoop"
    echo "                                                 (must be exectued at least once before creating cluster)"
    echo "       -c NUM_INSTANCES, --create=NUM_INSTANCES  Create a Docker based Bigtop Hadoop cluster"
    echo "       -p, --provision                           Deploy configuration changes"
    echo "       -s, --smoke-tests                         Run Bigtop smoke tests"
    echo "       -d, --destroy                             Destroy the cluster"
    echo "       -h, --help"
    exit 1
}

build-image() {
    echo "\$vagrantyamlconf = \"$vagrantyamlconf\"" > config.rb
    vagrant up image --provider docker
    {
        echo "echo -e '\nBUILD IMAGE SUCCESS.\n'" |vagrant ssh image
    } || {
        >&2 echo -e "\nBUILD IMAGE FAILED!\n"
	exit 2
    }
}

create() {
    echo "\$num_instances = $1" > config.rb
    echo "\$vagrantyamlconf = \"$vagrantyamlconf\"" >> config.rb
    vagrant up --no-parallel
    if [ $? -ne 0 ]; then
        echo "Docker container(s) startup failed!";
	exit 1;
    fi
    nodes=(`vagrant status |grep running |grep -v image |awk '{print $1}'`)
    hadoop_head_node=(`echo "hostname -f" |vagrant ssh ${nodes[0]} |tail -n 1`)
    repo=$(get-yaml-config repo)
    components="[`echo $(get-yaml-config components) | sed 's/ /, /g'`]"
    jdk=$(get-yaml-config jdk)
    distro=$(get-yaml-config distro)
    enable_local_repo=$(get-yaml-config enable_local_repo)

    # setup environment before running bigtop puppet deployment
    for node in ${nodes[*]}; do
        (
        echo "/bigtop-home/bigtop-deploy/vm/utils/setup-env-$distro.sh $enable_local_repo" |vagrant ssh $node
        echo "/vagrant/provision.sh $hadoop_head_node $repo \"$components\" $jdk" |vagrant ssh $node
        ) &
    done
    wait

    # run bigtop puppet (master node need to be provisioned before slave nodes)
    bigtop-puppet ${nodes[0]}
    for ((i=1 ; i<${#nodes[*]} ; i++)); do
        bigtop-puppet ${nodes[$i]} &
    done
    wait
}

provision() {
    nodes=(`vagrant status |grep running |grep -v image |awk '{print $1}'`)
    for node in ${nodes[*]}; do
        bigtop-puppet $node &
    done
    wait
}

smoke-tests() {
    nodes=(`vagrant status |grep running |grep -v image |awk '{print $1}'`)
    smoke_test_components="`echo $(get-yaml-config smoke_test_components) | sed 's/ /,/g'`"
    echo "/bigtop-home/bigtop-deploy/vm/utils/smoke-tests.sh \"$smoke_test_components\"" |vagrant ssh ${nodes[0]}
}


destroy() {
    nodes=(`vagrant status |grep running |grep -v image |awk '{print $1}'`)
    rm -rvf ./hosts ./config.rb
    for node in ${nodes[*]}; do
        vagrant destroy -f $node
    done
    wait
}

bigtop-puppet() {
    echo "puppet apply -d --modulepath=/bigtop-home/bigtop-deploy/puppet/modules:/etc/puppet/modules:/usr/share/puppet/modules /bigtop-home/bigtop-deploy/puppet/manifests/site.pp" |vagrant ssh $1
}

get-yaml-config() {
    RUBY_EXE=ruby
    which ruby > /dev/null 2>&1
    if [ $? -ne 0 ]; then
	# use vagrant embedded ruby on Windows
        RUBY_EXE=$(dirname $(which vagrant))/../embedded/bin/ruby
    fi
    RUBY_SCRIPT="data = YAML::load(STDIN.read); puts data['$1'];"
    cat ${vagrantyamlconf} | $RUBY_EXE -ryaml -e "$RUBY_SCRIPT" | tr -d '\r'
}

PROG=`basename $0`

if [ $# -eq 0 ]; then
    usage
fi

vagrantyamlconf="vagrantconfig.yaml"
while [ $# -gt 0 ]; do
    case "$1" in
    -b|--build-image)
        build-image
        shift;;
    -c|--create)
        if [ $# -lt 2 ]; then
          echo "Create requires a number" 1>&2
          usage
        fi
        create $2
        shift 2;;
    -C|--conf)
        if [ $# -lt 2 ]; then
          echo "Alternative config file for vagrantconfig.yaml" 1>&2
          usage
        fi
	vagrantyamlconf=$2
        shift 2;;
    -p|--provision)
        provision
        shift;;
    -s|--smoke-tests)
        smoke-tests
        shift;;
    -d|--destroy)
        destroy
        shift;;
    -h|--help)
        usage
        shift;;
    *)
        echo "Unknown argument: '$1'" 1>&2
        usage;;
    esac
done
