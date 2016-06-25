import re
import fileinput
from lxml import etree
import logging
sys.path.append('../../include/')
import py_functions

py_functions.setLogging()
logging.info('[%s] %s: Start SSH_AUTH_TEST reporter.', template_id, 'DEBUG')
ssh_auth_test =  etree.Element('SSH_AUTH_TEST')
allowed = False

for line in fileinput.input():
    regex = re.search('Permission\sdenied\s[(][a-z,-]+[,]password[a-z,)].*', line)
    if regex:
        ssh_auth_test.text = "SSH password authentication is allowed"
        allowed = True
        break

if not allowed:
    ssh_auth_test.text = "SSH password authentication is not allowed"

print etree.tostring(ssh_auth_test,pretty_print=True)

