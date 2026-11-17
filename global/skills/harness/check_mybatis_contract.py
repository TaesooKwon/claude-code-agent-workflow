#!/usr/bin/env python3
"""Validate Java Mapper interfaces against MyBatis XML mapper files."""

from __future__ import print_function

import argparse
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


STATEMENT_TAGS = set(["select", "insert", "update", "delete"])
JAVA_PRIMITIVES = set([
    "byte", "short", "int", "long", "float", "double", "boolean", "char", "void",
    "Byte", "Short", "Integer", "Long", "Float", "Double", "Boolean", "Character",
    "String", "Object", "Map", "List", "HashMap", "ArrayList",
    "java.lang.String", "java.lang.Integer", "java.lang.Long", "java.lang.Boolean",
    "java.lang.Double", "java.lang.Float", "java.lang.Object",
    "java.util.Map", "java.util.HashMap", "java.util.List", "java.util.ArrayList",
    "int[]", "long[]", "string", "map", "hashmap", "list", "arraylist",
    "_int", "_long", "_boolean", "_double", "_float", "integer", "long", "boolean",
])
PARAM_CONTAINER_TYPES = set([
    "Map", "HashMap", "List", "ArrayList", "Collection", "EgovMap",
    "java.util.Map", "java.util.HashMap", "java.util.List", "java.util.ArrayList", "java.util.Collection",
    "egovframework.rte.psl.dataaccess.util.EgovMap",
    "map", "hashmap", "list", "arraylist", "collection", "egovMap", "EgovMap",
])
MYBATIS_IMPLICIT_PARAMS = set([
    "array", "collection", "list", "map", "param1", "param2", "param3", "_parameter", "_databaseId",
])


def read_text(path):
    with open(path, "r") as handle:
        return handle.read()


def iter_files(root, suffix):
    for current_root, _, files in os.walk(root):
        for name in files:
            if name.endswith(suffix):
                yield os.path.join(current_root, name)


# 빌드 산출물·VCS·생성소스를 건너뛰며 레포 전체를 walk(멀티모듈/단일모듈 공통).
PRUNE_DIRS = set([
    "target", "build", "out", "bin", ".git", ".idea", ".gradle",
    "node_modules", "generated-sources", "generated", "dist",
])


def iter_repo_files(root, suffix):
    for current_root, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in PRUNE_DIRS]
        for name in files:
            if name.endswith(suffix):
                yield os.path.join(current_root, name)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//.*", "", text)
    return text


def split_top_level(value, delimiter=","):
    parts = []
    current = []
    depth = 0
    for char in value:
        if char == "<":
            depth += 1
        elif char == ">" and depth > 0:
            depth -= 1
        if char == delimiter and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    if current:
        parts.append("".join(current).strip())
    return parts


def erase_generics(type_name):
    return re.sub(r"<.*>", "", type_name).strip()


def parse_java_params(params_text):
    params = []
    for raw_param in split_top_level(params_text):
        if not raw_param:
            continue
        param_name_from_annotation = None
        annotation_match = re.search(r"@Param\s*\(\s*\"([^\"]+)\"\s*\)", raw_param)
        if annotation_match:
            param_name_from_annotation = annotation_match.group(1)
        cleaned = re.sub(r"@\w+(?:\([^)]*\))?", "", raw_param)
        cleaned = cleaned.replace("final ", " ").strip()
        tokens = cleaned.split()
        if len(tokens) < 2:
            continue
        name = param_name_from_annotation or tokens[-1].replace("...", "").strip()
        type_name = " ".join(tokens[:-1]).replace("...", "[]").strip()
        params.append({"name": name, "type": erase_generics(type_name)})
    return params


def parse_java_mapper(path):
    text = strip_comments(read_text(path))
    if "@Mapper" not in text:
        return None

    package_match = re.search(r"\bpackage\s+([\w.]+)\s*;", text)
    interface_match = re.search(r"\binterface\s+(\w+)\b", text)
    if not package_match or not interface_match:
        return None

    fqcn = package_match.group(1) + "." + interface_match.group(1)
    body_match = re.search(r"\binterface\s+\w+[^{]*\{(.*)\}\s*$", text, flags=re.S)
    body = body_match.group(1) if body_match else text

    methods = {}
    for match in re.finditer(r"(?:public\s+)?[\w.<>\[\], ?]+\s+(\w+)\s*\(([^;{}]*)\)\s*(?:throws\s+[\w.,\s]+)?;", body):
        name = match.group(1)
        if name not in ("if", "for", "while", "switch", "catch"):
            methods[name] = {"params": parse_java_params(match.group(2))}

    return {"path": path, "fqcn": fqcn, "methods": methods}


def parse_type_aliases(config_path):
    aliases = set(["egovMap", "EgovMap"])
    alias_types = {
        "egovMap": "egovframework.rte.psl.dataaccess.util.EgovMap",
        "EgovMap": "egovframework.rte.psl.dataaccess.util.EgovMap",
    }
    if not os.path.exists(config_path):
        return aliases, alias_types

    root = parse_xml(config_path)
    if root is None:
        return aliases, alias_types

    for node in root.findall(".//typeAlias"):
        alias = node.attrib.get("alias")
        type_name = node.attrib.get("type")
        if alias:
            aliases.add(alias)
            aliases.add(alias.lower())
            if type_name:
                alias_types[alias] = type_name
                alias_types[alias.lower()] = type_name
        if type_name:
            aliases.add(type_name)
    return aliases, alias_types


def parse_xml(path):
    parser = ET.XMLParser()
    try:
        return ET.parse(path, parser=parser).getroot()
    except ET.ParseError as exc:
        raise ValueError("%s: XML parse error: %s" % (path, exc))


def collect_local_vars(node):
    """XML 내부에서 생성돼 파라미터 객체의 필드가 아닌 변수명을 모은다.

    - <bind name="x" value="..."/>  → #{x}
    - <foreach item="x" index="i">  → #{x}, #{i}
    이 이름들은 DTO/메서드 파라미터에 존재할 필요가 없으므로 대조 대상에서 제외한다.
    """
    names = set()
    for bind in node.findall(".//bind"):
        name = bind.attrib.get("name")
        if name:
            names.add(name.strip())
    for foreach in node.findall(".//foreach"):
        for attr in ("item", "index"):
            value = foreach.attrib.get(attr)
            if value:
                names.add(value.strip())
    return names


NESTED_RESULT_TAGS = set(["association", "collection"])


def collect_result_map_entries(node, entry_id, type_name, entries):
    """resultMap 을 중첩 단위로 쪼개 (타입, property 묶음) 항목들을 만든다.

    <collection ofType="X">·<association javaType="X"> 하위의 property 는 바깥 타입이
    아니라 X 의 것이다. 전부 한 바구니에 담으면 정상 매핑이 대량 오탐으로 잡힌다.
    """
    properties = []
    associations = []
    for child in list(node):
        child_tag = child.tag.split("}")[-1]
        if child_tag == "discriminator":
            # <case> 의 매핑은 바깥 타입에 그대로 적용된다.
            for case_node in child.findall("case"):
                collect_result_map_entries(case_node, entry_id, type_name, entries)
            continue
        prop = child.attrib.get("property")
        if not prop:
            continue
        if child_tag in NESTED_RESULT_TAGS:
            if child.attrib.get("select"):
                associations.append(prop)
            else:
                properties.append(prop)
            # resultMap 속성으로 외부 정의를 참조하면 그 정의 쪽에서 따로 검사된다.
            nested_type = child.attrib.get("ofType") or child.attrib.get("javaType")
            if nested_type and not child.attrib.get("resultMap"):
                collect_result_map_entries(
                    child, "%s > %s" % (entry_id, prop), nested_type, entries)
            continue
        properties.append(prop)

    entries.append({
        "id": entry_id,
        "type": type_name,
        "properties": properties,
        "associations": associations,
    })


def parse_mapper_xml(path):
    root = parse_xml(path)
    if root.tag != "mapper":
        return None

    statements = []
    sql_ids = []
    includes = []
    internal_statement_refs = []
    typed_refs = []
    statement_details = {}
    sql_fragments = {}
    sql_fragment_vars = {}
    result_maps = []

    for node in list(root):
        tag = node.tag.split("}")[-1]
        node_id = node.attrib.get("id")
        if tag in STATEMENT_TAGS and node_id:
            statements.append(node_id)
            statement_details[node_id] = {
                "id": node_id,
                "tag": tag,
                "parameterType": node.attrib.get("parameterType"),
                "text": "".join(node.itertext()),
                "localVars": collect_local_vars(node),
                "includes": [include.attrib.get("refid") for include in node.findall(".//include") if include.attrib.get("refid")],
            }
        if tag == "sql" and node_id:
            sql_ids.append(node_id)
            sql_fragments[node_id] = "".join(node.itertext())
            sql_fragment_vars[node_id] = collect_local_vars(node)
        if tag == "resultMap":
            collect_result_map_entries(
                node, node_id or "(missing id)", node.attrib.get("type"), result_maps)
            for child in node.findall(".//*[@select]"):
                select_ref = child.attrib.get("select")
                if select_ref:
                    internal_statement_refs.append(select_ref)
        if tag in STATEMENT_TAGS:
            for attr in ("parameterType", "resultType", "resultMap"):
                value = node.attrib.get(attr)
                if value:
                    typed_refs.append((node_id or "(missing id)", attr, value))
        for include in node.findall(".//include"):
            refid = include.attrib.get("refid")
            if refid:
                includes.append((node_id or "(outside statement)", refid))

    return {
        "path": path,
        "namespace": root.attrib.get("namespace"),
        "statements": statements,
        "sql_ids": sql_ids,
        "includes": includes,
        "internal_statement_refs": internal_statement_refs,
        "typed_refs": typed_refs,
        "statement_details": statement_details,
        "sql_fragments": sql_fragments,
        "sql_fragment_vars": sql_fragment_vars,
        "result_maps": result_maps,
    }


def is_known_type(value, aliases, java_classes):
    if value in aliases or value.lower() in aliases or value in JAVA_PRIMITIVES:
        return True
    if value in java_classes:
        return True
    if "." in value:
        return value in java_classes or value.startswith(("java.", "egovframework.", "net."))
    return False


def parse_java_class(path):
    text = strip_comments(read_text(path))
    package_match = re.search(r"\bpackage\s+([\w.]+)\s*;", text)
    type_match = re.search(r"\b(?:class|interface|enum)\s+(\w+)\b", text)
    if not package_match or not type_match:
        return None

    package_name = package_match.group(1)
    simple_name = type_match.group(1)
    fqcn = package_name + "." + simple_name
    imports = {}
    for import_match in re.finditer(r"\bimport\s+([\w.]+)\s*;", text):
        import_name = import_match.group(1)
        imports[import_name.split(".")[-1]] = import_name

    parent = None
    extends_match = re.search(r"\bclass\s+" + re.escape(simple_name) + r"\s+extends\s+([\w.]+)", text)
    if extends_match:
        parent = extends_match.group(1)
        parent = imports.get(parent, package_name + "." + parent if "." not in parent else parent)

    fields = set()
    for field_match in re.finditer(r"\b(?:private|protected|public)\s+(?:static\s+)?(?:final\s+)?[\w.<>\[\], ?]+\s+(\w+)\s*(?:=|;)", text):
        fields.add(field_match.group(1))
    for getter_match in re.finditer(r"\b(?:get|is)([A-Z]\w*)\s*\(", text):
        name = getter_match.group(1)
        fields.add(name[0].lower() + name[1:])
    for setter_match in re.finditer(r"\bset([A-Z]\w*)\s*\(", text):
        name = setter_match.group(1)
        fields.add(name[0].lower() + name[1:])

    return {"path": path, "fqcn": fqcn, "simple": simple_name, "package": package_name, "fields": fields, "parent": parent, "imports": imports}


def resolve_type(type_name, current_class, simple_name_index, alias_types):
    if not type_name:
        return None
    type_name = erase_generics(type_name).replace("[]", "")
    if type_name in alias_types:
        return alias_types[type_name]
    if type_name in PARAM_CONTAINER_TYPES or type_name in JAVA_PRIMITIVES:
        return type_name
    if "." in type_name:
        return type_name
    if current_class and type_name in current_class.get("imports", {}):
        return current_class["imports"][type_name]
    if type_name in simple_name_index:
        return simple_name_index[type_name]
    if current_class:
        return current_class["package"] + "." + type_name
    return type_name


def collect_fields(fqcn, java_class_info, seen=None):
    if seen is None:
        seen = set()
    if not fqcn or fqcn in seen or fqcn not in java_class_info:
        return set()
    seen.add(fqcn)
    info = java_class_info[fqcn]
    fields = set(info["fields"])
    if info.get("parent"):
        fields.update(collect_fields(info["parent"], java_class_info, seen))
    return fields


def statement_text_with_includes(detail, sql_fragments):
    text = detail.get("text", "")
    for refid in detail.get("includes", []):
        if "." not in refid and refid in sql_fragments:
            text += "\n" + sql_fragments[refid]
    return text


def statement_local_vars(detail, sql_fragment_vars):
    names = set(detail.get("localVars") or set())
    for refid in detail.get("includes", []):
        if "." not in refid and refid in sql_fragment_vars:
            names.update(sql_fragment_vars[refid])
    return names


def extract_mybatis_properties(sql_text, local_vars=None):
    local_vars = local_vars or set()
    properties = set()
    for match in re.finditer(r"[#$]\{\s*([^},\s]+)", sql_text):
        value = match.group(1).strip()
        if not value:
            continue
        top_level = value.split(".")[0]
        if top_level in MYBATIS_IMPLICIT_PARAMS:
            continue
        if top_level in ("item", "index"):
            continue
        if top_level in local_vars:
            continue
        properties.add(top_level)
    return properties


def validate_statement_params(xml, mapper, mapper_class, java_class_info, simple_name_index, alias_types):
    warnings = []
    for statement, detail in sorted(xml["statement_details"].items()):
        if statement not in mapper["methods"]:
            continue
        local_vars = statement_local_vars(detail, xml.get("sql_fragment_vars", {}))
        sql_properties = extract_mybatis_properties(
            statement_text_with_includes(detail, xml["sql_fragments"]), local_vars)
        if not sql_properties:
            continue

        method_params = mapper["methods"][statement]["params"]
        param_names = set([param["name"] for param in method_params])
        unresolved_properties = set(sql_properties)

        if len(method_params) > 1:
            missing_named_params = sql_properties - param_names - MYBATIS_IMPLICIT_PARAMS
            for name in sorted(missing_named_params):
                warnings.append("%s: statement %s references '#{%s}' but Mapper method has params %s" % (
                    xml["path"], statement, name, sorted(param_names)))
            continue

        parameter_type = detail.get("parameterType")
        if parameter_type:
            resolved_type = resolve_type(parameter_type, mapper_class, simple_name_index, alias_types)
        elif len(method_params) == 1:
            resolved_type = resolve_type(method_params[0]["type"], mapper_class, simple_name_index, alias_types)
        else:
            resolved_type = None

        if not resolved_type or resolved_type in PARAM_CONTAINER_TYPES or resolved_type in JAVA_PRIMITIVES:
            continue
        if resolved_type not in java_class_info:
            continue

        fields = collect_fields(resolved_type, java_class_info)
        missing_fields = unresolved_properties - fields
        for name in sorted(missing_fields):
            warnings.append("%s: statement %s references '#{%s}' but %s has no matching field/getter/setter" % (
                xml["path"], statement, name, resolved_type))
    return warnings


def validate_result_maps(xml, mapper_class, java_class_info, simple_name_index, alias_types):
    warnings = []
    for result_map in xml["result_maps"]:
        result_type = resolve_type(result_map.get("type"), mapper_class, simple_name_index, alias_types)
        if not result_type or result_type in PARAM_CONTAINER_TYPES or result_type in JAVA_PRIMITIVES:
            continue
        if result_type not in java_class_info:
            continue

        fields = collect_fields(result_type, java_class_info)
        for prop in sorted(set(result_map["properties"] + result_map["associations"])):
            top_level = prop.split(".")[0]
            if top_level not in fields:
                warnings.append("%s: resultMap %s maps property '%s' but %s has no matching field/getter/setter" % (
                    xml["path"], result_map["id"], prop, result_type))
    return warnings


def git_changed_paths(project_root):
    try:
        git_root_output = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=project_root)
        git_root = git_root_output.decode("utf-8").strip()
    except (OSError, subprocess.CalledProcessError):
        git_root = project_root

    commands = [
        ["git", "diff", "--name-only"],
        ["git", "diff", "--name-only", "--cached"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ]
    changed = set()
    for command in commands:
        try:
            output = subprocess.check_output(command, cwd=project_root)
        except (OSError, subprocess.CalledProcessError):
            continue
        for line in output.decode("utf-8").splitlines():
            if line.strip():
                changed.add(os.path.abspath(os.path.join(git_root, line.strip())))
    return changed


def main():
    parser = argparse.ArgumentParser(description="Validate MyBatis mapper contracts.")
    parser.add_argument("--project-root", "--repo", dest="project_root", default=os.getcwd(),
                        help="레포 루트(멀티모듈이면 상위 루트). 매퍼 Java/XML은 레포 전체를 스캔한다.")
    parser.add_argument("--changed-only", action="store_true", help="Validate only changed Mapper interfaces and mapper XML files.")
    args = parser.parse_args()

    project_root = os.path.abspath(args.project_root)

    errors = []
    warnings = []
    duplicate_namespaces = []

    java_classes = set()
    java_class_info = {}
    simple_name_index = {}
    for path in iter_repo_files(project_root, ".java"):
        parsed_class = parse_java_class(path)
        if parsed_class:
            java_classes.add(parsed_class["fqcn"])
            java_class_info[parsed_class["fqcn"]] = parsed_class
            simple_name_index[parsed_class["simple"]] = parsed_class["fqcn"]

    java_mappers = {}
    for path in iter_repo_files(project_root, "Mapper.java"):
        parsed = parse_java_mapper(path)
        if parsed:
            java_mappers[parsed["fqcn"]] = parsed

    # typeAlias = 레포 내 모든 mapper-config.xml 병합(멀티모듈 대비). 기본 egovMap 별칭 시드.
    aliases = set(["egovMap", "EgovMap"])
    alias_types = {
        "egovMap": "egovframework.rte.psl.dataaccess.util.EgovMap",
        "EgovMap": "egovframework.rte.psl.dataaccess.util.EgovMap",
    }
    for cfg in iter_repo_files(project_root, "mapper-config.xml"):
        cfg_aliases, cfg_types = parse_type_aliases(cfg)
        aliases |= cfg_aliases
        alias_types.update(cfg_types)

    # 매퍼 XML = 네이밍(_SQL.xml/_sql.xml/Mapper.xml 등) 가정 없이 `mapper/` 경로의
    # .xml 을 내용으로 식별(parse_mapper_xml 이 root!=<mapper> 면 None 반환).
    xml_mappers = {}
    sep = os.sep
    for path in iter_repo_files(project_root, ".xml"):
        if (sep + "mapper" + sep) not in path.lower():
            continue
        try:
            parsed = parse_mapper_xml(path)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        if not parsed:
            continue
        namespace = parsed["namespace"]
        if not namespace:
            errors.append("%s: missing mapper namespace" % parsed["path"])
            continue
        if namespace in xml_mappers:
            duplicate_namespaces.append((namespace, xml_mappers[namespace]["path"], parsed["path"]))
        xml_mappers[namespace] = parsed

    target_namespaces = set(xml_mappers.keys())
    if args.changed_only:
        changed = git_changed_paths(project_root)
        target_namespaces = set()
        xml_by_path = dict((os.path.abspath(item["path"]), item) for item in xml_mappers.values())
        mapper_by_path = dict((os.path.abspath(item["path"]), item) for item in java_mappers.values())

        for path in changed:
            if path in xml_by_path:
                target_namespaces.add(xml_by_path[path]["namespace"])
            if path in mapper_by_path:
                target_namespaces.add(mapper_by_path[path]["fqcn"])

        if not target_namespaces:
            print("MyBatis contract check")
            print("Project root: %s" % project_root)
            print("Changed Mapper/XML files: 0")
            print("No changed MyBatis mapper contracts to validate.")
            return 0

    for namespace, first_path, second_path in duplicate_namespaces:
        if namespace in target_namespaces or not args.changed_only:
            errors.append("Duplicate mapper namespace %s:\n  - %s\n  - %s" % (
                namespace, first_path, second_path))

    for fqcn, mapper in sorted(java_mappers.items()):
        if fqcn not in target_namespaces:
            continue
        xml = xml_mappers.get(fqcn)
        if not xml:
            errors.append("%s: no XML mapper namespace for %s" % (mapper["path"], fqcn))
            continue

        java_methods = set(mapper["methods"].keys())
        xml_statements = set(xml["statements"])
        internal_statement_refs = set(xml["internal_statement_refs"])

        for method in sorted(java_methods - xml_statements):
            errors.append("%s: method %s is missing XML statement id in %s" % (
                mapper["path"], method, xml["path"]))

        for statement in sorted(xml_statements - java_methods - internal_statement_refs):
            warnings.append("%s: XML statement id %s has no Java Mapper method in %s" % (
                xml["path"], statement, mapper["path"]))

        seen = set()
        for statement in xml["statements"]:
            if statement in seen:
                errors.append("%s: duplicate statement id %s" % (xml["path"], statement))
            seen.add(statement)

        sql_ids = set(xml["sql_ids"])
        for statement, refid in xml["includes"]:
            if "." not in refid and refid not in sql_ids:
                errors.append("%s: statement %s includes missing sql refid %s" % (
                    xml["path"], statement, refid))

        for statement, attr, value in xml["typed_refs"]:
            if attr == "resultMap":
                continue
            if not is_known_type(value, aliases, java_classes):
                warnings.append("%s: statement %s uses unknown %s '%s'" % (
                    xml["path"], statement, attr, value))

        mapper_class = java_class_info.get(fqcn)
        warnings.extend(validate_statement_params(
            xml, mapper, mapper_class, java_class_info, simple_name_index, alias_types))
        warnings.extend(validate_result_maps(
            xml, mapper_class, java_class_info, simple_name_index, alias_types))

    for namespace, xml in sorted(xml_mappers.items()):
        if namespace not in target_namespaces:
            continue
        if namespace not in java_mappers:
            warnings.append("%s: XML namespace %s has no @Mapper interface" % (xml["path"], namespace))

    print("MyBatis contract check")
    print("Project root: %s" % project_root)
    if args.changed_only:
        print("Scope: changed Mapper/XML contracts")
        print("Target namespaces: %d" % len(target_namespaces))
    print("Java mappers: %d" % len(java_mappers))
    print("XML mappers: %d" % len(xml_mappers))
    print("Errors: %d" % len(errors))
    print("Warnings: %d" % len(warnings))

    if errors:
        print("\nERRORS")
        for item in errors:
            print("- %s" % item)

    if warnings:
        print("\nWARNINGS")
        for item in warnings:
            print("- %s" % item)

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
