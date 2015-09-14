#!/usr/bin/python

from halonvsi.docker import *

OMD_DOCKER_IMAGE = 'openswitch/omd'

class OmdSwitch (DockerNode, Switch):
    def __init__(self, name, image=OMD_DOCKER_IMAGE, **kwargs):
        kwargs['nodetype'] = "HalonHost"
        kwargs['init_cmd'] = DOCKER_DEFAULT_CMD
        super(OmdSwitch, self).__init__(name, image, **kwargs)
        self.inNamespace = True

    def start(self, controllers):
        pass
