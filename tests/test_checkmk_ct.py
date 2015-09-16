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
import inspect
from halonvsi.docker import *
from halonvsi.halon import *
from halonutils.halonutil import *

class myTopo(Topo):
    def build (self, hsts=0, sws=1, **_opts):
        self.hsts = hsts
        self.sws = sws
        switch = self.addSwitch("s1")

class checkmkTest (HalonTest):
    def setupNet (self):
        self.net = Mininet(topo=myTopo(hsts = 0,
                                       sws = 1,
                                       hopts = self.getHostOpts(),
                                       sopts = self.getSwitchOpts()),
                                       switch = HalonSwitch,
                                       host = HalonHost,
                                       link = HalonLink,
                                       controller = None,
                                       build = True)
        print "%s PASSED." % inspect.stack()[0][3]

    def configure_switch (self):
        for switch in self.net.switches:
            switch.cmd("systemctl enable checkmk-agent.socket")
            switch.cmd("systemctl restart sockets.target")
            cmd = "configure terminal"
            print cmd
            switch.cmdCLI(cmd)
            cmd = "interface 1"
            print cmd
            switch.cmdCLI(cmd)
            cmd = "no shutdown"
            print cmd
            switch.cmdCLI(cmd)
            switch.cmdCLI("exit")
        print "%s PASSED." % inspect.stack()[0][3]

    def verify_checkmk_local (self):
        time.sleep(30)
        for switch in self.net.switches:
            result = switch.cmd("/usr/bin/check_mk_agent")
            ifInfo = re.findall('lnx_if\:sep\(58\)\>\>\>(.*)\<\<\<ovs_bonding', result, re.DOTALL)
            if (ifInfo == None) or (ifInfo == ['\r\n']):
                print '%s FAILED.' % inspect.stack()[0][3]
                assert 'check_mk_agent failed to get interface info'
            else:
                print ifInfo
                print "%s PASSED." % inspect.stack()[0][3]

    def verify_checkmk_telnet (self):
        pass

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
        self.test_var.configure_switch()
        self.test_var.verify_checkmk_local()
        self.test_var.verify_checkmk_telnet()
