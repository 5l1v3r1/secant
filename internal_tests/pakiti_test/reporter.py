import re, sys, os
from lxml import etree

template_id = sys.argv[1]

pakiti =  etree.Element('PAKITI_TEST')
pakiti_data= sys.stdin.readlines()

if pakiti_data[0] == 'ERROR':
    pakiti.set('status', 'FAIL')
    #error = etree.SubElement(pakiti, "ERROR")
    pakiti.text = "Pakiti error appears during data processing."
    pakiti.set('status', 'FAIL')
elif pakiti_data[0] == 'FAIL':
    pakiti.set('status', 'FAIL')
elif pakiti_data[0] == 'SKIP':
    pakiti.set('status', 'SKIP')
else:
    for line in pakiti_data:
        if line[:2] == "OK":
            pakiti.text = "No vulnerable packages."
            break
        if line[:5] == "ERROR":
            pakiti.text = "Pakiti reported ERROR status."
            pakiti.set('status', 'FAIL')
            break
        pkg_list = re.split('\s+', line[2:])
        pkg = etree.SubElement(pakiti, "PKG")
        pkg.text = pkg_list[0] + ", " + pkg_list[1] + ", " + pkg_list[2]

if 'status' not in pakiti.attrib:
    pakiti.set('status', 'OK')
print etree.tostring(pakiti,pretty_print=True)


