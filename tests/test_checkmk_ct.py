#
# !/usr/bin/python
#
# Copyright (C) 2015 Hewlett Packard Enterprise Development LP
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

import os
import sys
import time
import pytest
import subprocess
import time
import re
from halonvsi.docker import *
from halonvsi.halon import *
from halonutils.halonutil import *
from halonvsi.omd import *

NUM_OF_SWITCHES = 1
NUM_HOSTS_PER_SWITCH = 0

SWITCH = "s1"
OMD_SERVER = "s2"
OMD_IP = "9.0.0.1"
SWITCH_IP = "9.0.0.2"
NETMASK = "24"

class myTopo(Topo):
    def build (self, hsts=0, sws=NUM_OF_SWITCHES, **_opts):

        self.hsts = hsts
        self.sws = sws

        self.addSwitch(SWITCH)
        self.addSwitch(name = OMD_SERVER, cls = OmdSwitch, **self.sopts)
        self.addLink(SWITCH, OMD_SERVER)

class checkmkTest (HalonTest):
    def setupNet (self):
        self.net = Mininet(topo=myTopo(hsts = NUM_HOSTS_PER_SWITCH,
                                       sws = NUM_OF_SWITCHES + 1,
                                       hopts = self.getHostOpts(),
                                       sopts = self.getSwitchOpts()),
                                       switch = HalonSwitch,
                                       host = HalonHost,
                                       link = HalonLink,
                                       controller = None,
                                       build = True)

    def configure_switch_ips (self):
        info("\n########## Configuring switch IPs.. ##########\n")

        for switch in self.net.switches:
            if isinstance(switch, HalonSwitch):
                switch.cmd("systemctl enable checkmk-agent.socket")
                switch.cmd("systemctl restart sockets.target")
                switch.cmdCLI("configure terminal")
                switch.cmdCLI("interface 1")
                switch.cmdCLI("no shutdown")
                switch.cmdCLI("ip address %s/%s" % (SWITCH_IP, NETMASK)),
                switch.cmdCLI("exit")
            else:
                switch.setIP(ip=OMD_IP, intf="%s-eth1" % switch.name)

    def verify_checkmk_interface_info (self):
        info("\n########## Verifying checkmk agent.. ##########\n")
        # Wait for interface info to be reflected in ovsdb
        time.sleep(30)
        for switch in self.net.switches:
            if isinstance(switch, HalonSwitch):
                result = switch.cmd("/usr/bin/check_mk_agent")
                ifInfo = re.findall('lnx_if\:sep\(58\)\>\>\>(.*)\<\<\<ovs_bonding', result, re.DOTALL)
                if (ifInfo == None) or (ifInfo == ['\r\n']):
                    print 'check_mk_agent failed to get interface info'
                    assert 'check_mk_agent failed to get interface info'

class Test_checkmk_basic_setup:
    def setup (self):
        pass

    def teardown (self):
        pass

    def setup_class (cls):
        Test_checkmk_basic_setup.test_var = checkmkTest()

    def teardown_class (cls):
        Test_checkmk_basic_setup.test_var.net.stop()

    def setup_method (self, method):
        pass

    def teardown_method (self, method):
        pass

    def __del__ (self):
        del self.test_var

    def test_run (self):
        self.test_var.configure_switch_ips()
        self.test_var.verify_checkmk_interface_info()
