#!/usr/bin/env python3
import yaml
import xml.etree.ElementTree as ET


def dict_to_xml(tag, d):
    elem = ET.Element(tag)
    for key, val in d.items():
        child = ET.Element(key)
        if isinstance(val, dict):
            child.append(dict_to_xml(key, val))
        else:
            child.text = str(val)
        elem.append(child)
    return elem


# Load YAML file
with open('./ubuntu-template.yaml') as f:
    config = yaml.safe_load(f)

# Convert YAML to XML
xml_root = dict_to_xml('domain', config['domain'])

# Generate XML string
xml_str = ET.tostring(xml_root, encoding='unicode')

# Write to file
with open('vm_config.xml', 'w') as f:
    f.write(xml_str)
