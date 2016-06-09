# -*- coding: utf-8 -*-
#
# Copyright (C) 2016 Hewlett Packard Enterprise Development LP
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

import re
from ipdb import set_trace
import time

TOPOLOGY = """
#
# +-------+
# |  sw1  |
# +-------+
#

# Nodes
[type=openswitch name="Switch 1"] sw1

# Links
sw1:1
"""


def test_checkmk_basic_setup(topology, step):
    step("\n########## Test Check_mk agent mosule-stress-test ##########\n")
    step("\n########## Test Check_mk agent (local invocation) ##########\n")
    sw1 = topology.get('sw1')

    #set_trace()
    time.sleep(10800)
    assert sw1 is not None

    # Configure interfaces
    with sw1.libs.vtysh.ConfigInterface('1') as ctx:
        ctx.no_shutdown()

    result = sw1("/usr/bin/check_mk_agent", shell="bash")
    if_info = re.findall('lnx_if\:sep\(58\)\>\>\>(.*)\<\<\<ovs_bonding',
                         result, re.DOTALL)
    assert if_info is not None and if_info != ['\r\n'], "check_mk failed"
