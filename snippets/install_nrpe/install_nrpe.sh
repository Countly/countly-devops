#!/bin/bash

if [ -f /etc/lsb-release ]; then
    apt update
    apt-get install nagios-nrpe-server nagios-plugins git -y
    curl https://bootstrap.pypa.io/pip/2.7/get-pip.py > /tmp/get-pip.py
    python2 /tmp/get-pip.py

    cd /usr/lib/nagios/plugins/

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_mem.sh > check_mem
    chmod +x check_mem

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_countly_ping.sh > check_countly_ping
    chmod +x check_countly_ping

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_countly_uptime.sh > check_countly_uptime
    chmod +x check_countly_uptime

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_mongodb_log_pthread.sh > check_mongodb_log_pthread
    chmod +x check_mongodb_log_pthread

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_cpu_percent.sh > check_cpu_usage
    chmod +x check_cpu_usage

    rm -rf nagios-plugin-mongodb check_mongodb.py
    git clone git://github.com/mzupan/nagios-plugin-mongodb.git
    cd nagios-plugin-mongodb
    pip install -r requirements
    cp check_mongodb.py ../
    cd ../
    chmod +x check_mongodb.py

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/nrpe_ubuntu.cfg > /etc/nagios/nrpe.cfg

    systemctl restart nagios-nrpe-server
    systemctl enable nagios-nrpe-server
elif [ -f /etc/redhat-release ]; then
    yum install epel-release -y
    yum install nrpe nagios-plugins-all python-pip git -y

    cd /usr/lib64/nagios/plugins/

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_mem.sh > check_mem
    chmod +x check_mem

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_countly_ping.sh > check_countly_ping
    chmod +x check_countly_ping

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_countly_uptime.sh > check_countly_uptime
    chmod +x check_countly_uptime

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_mongodb_log_pthread.sh > check_mongodb_log_pthread
    chmod +x check_mongodb_log_pthread

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/check_cpu_percent.sh > check_cpu_usage
    chmod +x check_cpu_usage

    rm -rf nagios-plugin-mongodb check_mongodb.py
    git clone git://github.com/mzupan/nagios-plugin-mongodb.git
    cd nagios-plugin-mongodb
    pip install -r requirements
    cp check_mongodb.py ../
    cd ../
    chmod +x check_mongodb.py

    curl -L https://bitbucket.org/api/2.0/snippets/countly/BMkAnx/files/nrpe_centos.cfg > /etc/nagios/nrpe.cfg

    service nrpe restart
    chkconfig nrpe on
fi
