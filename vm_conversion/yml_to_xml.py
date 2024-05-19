#!/usr/bin/env python3
import yaml
import xml.etree.ElementTree as ET
from xml.dom import minidom


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


def prettify_xml(elem):
    """Return a pretty-printed XML string for the Element."""
    rough_string = ET.tostring(elem, 'utf-8')
    reparsed = minidom.parseString(rough_string)
    return reparsed.toprettyxml(indent="  ")


# Load YAML file
with open('./ubuntu-template.yaml') as f:
    config = yaml.safe_load(f)
# Convert YAML to XML
xml_root = dict_to_xml('domain', config['domain'])
# Generate pretty XML string
xml_str = prettify_xml(xml_root)
# Write to file
with open('vm_config.xml', 'w') as f:
    f.write(xml_str)


# def dict_to_xml(tag, d):
#     elem = ET.Element(tag)
#     for key, val in d.items():
#         child = ET.Element(key)
#         if isinstance(val, dict):
#             child.append(dict_to_xml(key, val))
#         else:
#             child.text = str(val)
#         elem.append(child)
#     return elem
#
#
# # Load YAML file
# with open('./ubuntu-template.yaml') as f:
#     config = yaml.safe_load(f)
#
# # Convert YAML to XML
# xml_root = dict_to_xml('domain', config['domain'])
#
# # Generate XML string
# xml_str = ET.tostring(xml_root, encoding='unicode')
#
# # Write to file
# with open('vm_config.xml', 'w') as f:
#     f.write(xml_str)
