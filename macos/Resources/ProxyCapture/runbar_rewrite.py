"""Bounded, lossless JSON response rewriting shared by capture and local tests.

The parser keeps byte spans. Unselected text (including decimal spellings and
large integers) is never round-tripped through Python's floating point encoder.
This module deliberately has no mitmproxy dependency.
"""
import base64
import json
import os
import re
import shutil
import uuid
import zlib
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

BODY_LIMIT = 1024 * 1024
ARTIFACT_LIMIT = 4 * 1024 * 1024
MAX_DEPTH = 128
MAX_NODES = 200_000
MAX_CHANGES = 8192
NUMBER = re.compile(rb"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")


class RewriteError(ValueError):
    pass


class Node:
    __slots__ = ("start", "end", "kind", "value")

    def __init__(self, start, end, kind, value):
        self.start, self.end, self.kind, self.value = start, end, kind, value


class JSONDocument:
    def __init__(self, data, limit=BODY_LIMIT):
        if isinstance(data, str):
            data = data.encode("utf-8")
        if len(data) > limit:
            raise RewriteError("JSON 正文超过 1 MB 改写上限")
        try:
            data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise RewriteError("JSON 正文不是有效的 UTF-8") from error
        self.data = data
        self.index = 0
        self.count = 0
        self.root = self.read(0)
        self.space()
        if self.index != len(data):
            raise RewriteError("JSON 正文包含多余内容")

    def space(self):
        while self.index < len(self.data) and self.data[self.index] in b" \r\n\t":
            self.index += 1

    def string(self):
        start = self.index
        self.index += 1
        while self.index < len(self.data):
            byte = self.data[self.index]
            self.index += 1
            if byte == 92:
                self.index += 1
            elif byte == 34:
                try:
                    value = json.loads(self.data[start:self.index])
                    value.encode("utf-8")
                    return value
                except (ValueError, UnicodeError) as error:
                    raise RewriteError("JSON 字符串无效") from error
        raise RewriteError("JSON 字符串未结束")

    def read(self, depth):
        self.space()
        self.count += 1
        if depth > MAX_DEPTH or self.count > MAX_NODES:
            raise RewriteError("JSON 结构超过改写复杂度上限")
        start = self.index
        if start >= len(self.data):
            raise RewriteError("JSON 正文不完整")
        byte = self.data[start]
        if byte == 34:
            return self.read_string(start)
        if byte in (123, 91):
            object_mode = byte == 123
            end_byte = 125 if object_mode else 93
            value = {} if object_mode else []
            self.index += 1
            self.space()
            if self.index < len(self.data) and self.data[self.index] == end_byte:
                self.index += 1
                return Node(start, self.index, "object" if object_mode else "array", value)
            while True:
                self.space()
                if object_mode:
                    if self.index >= len(self.data) or self.data[self.index] != 34:
                        raise RewriteError("JSON 对象字段名无效")
                    key = self.string()
                    if key in value:
                        raise RewriteError("JSON 对象存在重复字段名")
                    self.space()
                    if self.index >= len(self.data) or self.data[self.index] != 58:
                        raise RewriteError("JSON 对象缺少冒号")
                    self.index += 1
                    value[key] = self.read(depth + 1)
                else:
                    value.append(self.read(depth + 1))
                self.space()
                if self.index >= len(self.data):
                    raise RewriteError("JSON 正文不完整")
                separator = self.data[self.index]
                self.index += 1
                if separator == end_byte:
                    return Node(start, self.index, "object" if object_mode else "array", value)
                if separator != 44:
                    raise RewriteError("JSON 分隔符无效")
        for token, kind, value in [(b"true", "boolean", True), (b"false", "boolean", False), (b"null", "null", None)]:
            if self.data.startswith(token, start):
                self.index += len(token)
                return Node(start, self.index, kind, value)
        number = NUMBER.match(self.data, start)
        if number:
            self.index = number.end()
            try:
                return Node(start, self.index, "number", Decimal(number.group().decode("ascii")))
            except InvalidOperation as error:
                raise RewriteError("JSON 数字超出可处理范围") from error
        raise RewriteError("正文不是有效的 JSON")

    def read_string(self, start):
        value = self.string()
        return Node(start, self.index, "string", value)

    def raw(self, node):
        return self.data[node.start:node.end].decode("utf-8")


def equal(left, right):
    if left.kind != right.kind:
        return False
    if left.kind == "object":
        return left.value.keys() == right.value.keys() and all(equal(v, right.value[k]) for k, v in left.value.items())
    if left.kind == "array":
        return len(left.value) == len(right.value) and all(equal(a, b) for a, b in zip(left.value, right.value))
    return left.value == right.value


def subset(expected, actual):
    if expected.kind == "object":
        return actual.kind == "object" and all(k in actual.value and subset(v, actual.value[k]) for k, v in expected.value.items())
    return equal(expected, actual)


def contains(actual, expected):
    if actual.kind == "array":
        return any(equal(child, expected) for child in actual.value)
    return actual.kind == expected.kind == "string" and expected.value in actual.value


ANY_INDEX = object()


def path_parts(path):
    if not isinstance(path, str) or len(path) > 1024:
        raise RewriteError("字段路径无效或过长")
    path = path.strip()
    if not path:
        raise RewriteError("请填写字段路径")
    index, result = (1 if path.startswith("$") else 0), []
    if index == len(path):
        return result
    if index and path[index] == ".":
        index += 1
    while index < len(path):
        if path[index] == "[":
            index += 1
            if index < len(path) and path[index] == '"':
                try:
                    key, count = json.JSONDecoder().raw_decode(path[index:])
                except ValueError as error:
                    raise RewriteError("字段路径的引号无效") from error
                if not isinstance(key, str):
                    raise RewriteError("字段路径无效")
                index += count
                result.append(key)
            else:
                end = path.find("]", index)
                if end < 0:
                    raise RewriteError("字段路径缺少 ]")
                token = path[index:end]
                if token == "*":
                    result.append(ANY_INDEX)
                elif token and token.isascii() and token.isdigit() and len(token) <= 9:
                    result.append(int(token))
                else:
                    raise RewriteError("数组路径只支持下标或 [*]")
                index = end
            if index >= len(path) or path[index] != "]":
                raise RewriteError("字段路径缺少 ]")
            index += 1
        else:
            start = index
            while index < len(path) and path[index] not in ".[]":
                index += 1
            if start == index:
                raise RewriteError("字段路径格式不正确")
            result.append(path[start:index])
        if len(result) > 64:
            raise RewriteError("字段路径超过 64 层")
        if index < len(path) and path[index] == ".":
            index += 1
            if index == len(path) or path[index] in ".[":
                raise RewriteError("字段路径格式不正确")
        elif index < len(path) and path[index] != "[":
            raise RewriteError("字段路径格式不正确")
    return result


def concrete_path(parts):
    return "$" + "".join("[" + (str(part) if isinstance(part, int) else json.dumps(part, ensure_ascii=True)) + "]" for part in parts)


def locate(node, parts, strict=True):
    matches = [(node, [])]
    for part in parts:
        following = []
        for value, actual in matches:
            if part is ANY_INDEX and value.kind == "array":
                following.extend((child, actual + [i]) for i, child in enumerate(value.value))
            elif isinstance(part, str) and value.kind == "object" and part in value.value:
                following.append((value.value[part], actual + [part]))
            elif isinstance(part, int) and value.kind == "array" and part < len(value.value):
                following.append((value.value[part], actual + [part]))
            elif strict:
                raise RewriteError("响应字段路径不存在或结构不符")
        matches = following
    return matches


def bounded_decode(data, encoding):
    if len(data) > BODY_LIMIT:
        raise RewriteError("正文超过 1 MB 改写上限")
    encoding = (encoding or "identity").strip().lower()
    if encoding in ("", "identity"):
        return data
    if encoding not in ("gzip", "deflate"):
        raise RewriteError("暂不支持 Content-Encoding=" + encoding)
    modes = [31] if encoding == "gzip" else [15, -15]
    for mode in modes:
        try:
            decoder = zlib.decompressobj(mode)
            result = decoder.decompress(data, BODY_LIMIT + 1)
            if len(result) > BODY_LIMIT or decoder.unconsumed_tail:
                raise RewriteError("解压后正文超过 1 MB 改写上限")
            if not decoder.eof or decoder.unused_data:
                raise RewriteError("压缩正文不完整或包含额外数据")
            return result
        except zlib.error as error:
            if mode == modes[-1]:
                raise RewriteError("无法解压响应正文") from error
    raise RewriteError("无法解压响应正文")


def bounded_encode(data, encoding):
    if len(data) > BODY_LIMIT:
        raise RewriteError("改写后正文超过 1 MB 上限")
    encoding = (encoding or "identity").strip().lower()
    if encoding in ("", "identity"):
        result = data
    elif encoding in ("gzip", "deflate"):
        compressor = zlib.compressobj(wbits=31 if encoding == "gzip" else 15)
        result = compressor.compress(data) + compressor.flush()
    else:
        raise RewriteError("不支持的响应编码")
    if len(result) > BODY_LIMIT:
        raise RewriteError("改写后编码正文超过 1 MB 上限")
    return result


def json_condition(text, object_only=False):
    if not isinstance(text, str):
        raise RewriteError("JSON 条件必须为文本")
    if not text.strip():
        return None
    result = JSONDocument(text)
    if object_only and result.root.kind != "object":
        raise RewriteError("匹配条件必须是 JSON 对象")
    return result


class Rule:
    def __init__(self, source, revision):
        self.source = source
        self.revision = revision
        self.id = str(source.get("id", ""))
        try:
            uuid.UUID(self.id)
        except (ValueError, AttributeError) as error:
            raise RewriteError("规则 ID 无效") from error
        self.name = source.get("name", "")
        notes = source.get("notes", "")
        if not isinstance(self.name, str) or not self.name.strip() or len(self.name) > 80:
            raise RewriteError("规则名称必填且不能超过 80 字")
        if not isinstance(notes, str) or len(notes) > 500:
            raise RewriteError("备注不能超过 500 字")
        self.enabled = source.get("enabled", True)
        method = source.get("method", "")
        if not isinstance(self.enabled, bool) or not isinstance(method, str) or len(method.encode("utf-8")) > 64 or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in method):
            raise RewriteError("规则启用状态或请求方法无效")
        self.method = method.upper()
        self.url_mode = source.get("urlMode", "path")
        self.url_pattern = source.get("urlPattern", "")
        if self.url_mode not in ("full", "path", "contains") or not isinstance(self.url_pattern, str) or not self.url_pattern.strip() or len(self.url_pattern.encode("utf-8")) > 16_384:
            raise RewriteError("请填写有效的 URL 匹配条件")
        if self.url_mode == "full" and urlsplit(self.url_pattern).scheme.lower() not in ("http", "https"):
            raise RewriteError("完整 URL 必须以 http:// 或 https:// 开头")
        if self.url_mode == "path" and not self.url_pattern.startswith("/"):
            raise RewriteError("路径必须以 / 开头")
        self.request = json_condition(source.get("requestJSON", ""), True)
        self.query = json_condition(source.get("queryJSON", ""), True)
        if self.query:
            for value in self.query.root.value.values():
                if value.kind != "string" and not (value.kind == "array" and all(v.kind == "string" for v in value.value)):
                    raise RewriteError("URL 查询参数的值必须为字符串或字符串数组")
        conditions = source.get("requestConditions", [])
        actions = source.get("actions", [])
        if not isinstance(conditions, list) or len(conditions) > 32 or not isinstance(actions, list) or not 1 <= len(actions) <= 32:
            raise RewriteError("每条规则需有 1–32 个替换项，附加条件最多 32 个")
        for collection in (conditions, actions):
            identifiers = [item["id"] for item in collection if "id" in item]
            if len(set(identifiers)) != len(identifiers):
                raise RewriteError("条件或替换项的 ID 重复")
        self.conditions = []
        for condition in conditions:
            operation = condition.get("operation", "equals")
            if operation not in ("equals", "contains"):
                raise RewriteError("请求比较方式无效")
            value = json_condition(condition.get("valueJSON", ""))
            if value is None:
                raise RewriteError("请填写请求条件的 JSON 比较值")
            self.conditions.append((path_parts(condition.get("path", "")), operation, value.root))
        self.actions = []
        for action in actions:
            kind = action.get("kind", "json")
            if kind not in ("json", "table"):
                raise RewriteError("响应替换类型无效")
            replacement = json_condition(action.get("valueJSON", ""))
            if replacement is None:
                raise RewriteError("请填写替换 JSON 值")
            parts = path_parts(action.get("path", ""))
            row_conditions = json_condition(action.get("rowConditionsJSON", ""), True)
            header = action.get("headerRow", 0)
            column = action.get("column", "")
            if kind == "table" and (type(header) is not int or header < 0 or header > 100_000 or not isinstance(column, str) or not column):
                raise RewriteError("表头行号或列名无效")
            self.actions.append((kind, parts, column, header, row_conditions, replacement))

    @property
    def needs_body(self):
        return self.request is not None or bool(self.conditions)

    def matches_headers(self, method, url):
        if self.method and method.upper() != self.method:
            return False
        parts = urlsplit(url)
        actual = parts.path if self.url_mode == "path" else url
        if self.url_mode == "contains":
            if self.url_pattern not in actual:
                return False
        elif self.url_pattern != actual:
            return False
        if self.query:
            values = {key: items if len(items) > 1 else items[0] for key, items in parse_qs(parts.query, keep_blank_values=True).items()}
            actual_query = JSONDocument(json.dumps(values, ensure_ascii=True))
            if not subset(self.query.root, actual_query.root):
                return False
        return True

    def matches_body(self, document):
        if not self.needs_body:
            return True
        if document is None:
            raise RewriteError("请求正文未完整采集，无法校验参数")
        if self.request and not subset(self.request.root, document.root):
            return False
        for parts, operation, expected in self.conditions:
            values = locate(document.root, parts, strict=False)
            compare = equal if operation == "equals" else contains
            if not any(compare(actual, expected) for actual, _ in values):
                return False
        return True

    def summary(self, state, count=0, reason=None, artifact_id=None):
        result = {"state": state, "count": count, "ruleID": self.id, "ruleName": self.name, "revision": self.revision}
        if reason:
            result["reason"] = reason
        if artifact_id:
            result["artifactID"] = artifact_id
        return result

    def apply(self, data):
        document = JSONDocument(data)
        targets = []
        for kind, parts, column, header_index, row_conditions, replacement in self.actions:
            located = locate(document.root, parts)
            if kind == "table":
                if len(located) != 1:
                    raise RewriteError("表格路径必须定位一个数组")
                table, base = located[0]
                if table.kind != "array" or header_index >= len(table.value):
                    raise RewriteError("表格路径或表头行不存在")
                header = table.value[header_index]
                if header.kind != "array" or not all(v.kind == "string" for v in header.value):
                    raise RewriteError("表头必须为字符串数组")
                names = [v.value for v in header.value]
                if len(set(names)) != len(names):
                    raise RewriteError("表头存在重复列名")
                if column not in names:
                    raise RewriteError("找不到表头字段“" + column + "”")
                if row_conditions and any(key not in names for key in row_conditions.root.value):
                    raise RewriteError("行筛选条件的字段不在表头中")
                column_index = names.index(column)
                selected = []
                for index in range(header_index + 1, len(table.value)):
                    row = table.value[index]
                    if row.kind != "array" or len(row.value) != len(names):
                        raise RewriteError("第 " + str(index + 1) + " 行结构不完整")
                    logical_row = Node(row.start, row.end, "object", dict(zip(names, row.value)))
                    if row_conditions and not subset(row_conditions.root, logical_row):
                        continue
                    selected.append((row.value[column_index], base + [index, column_index]))
                located = selected
            for node, actual_path in located:
                targets.append((node, actual_path, replacement))
                if len(targets) > MAX_CHANGES:
                    raise RewriteError("定位数量超过 8192 个值的改写上限")
        targets.sort(key=lambda item: item[0].start)
        previous_end = -1
        changes = []
        replacements = []
        output_size = len(data)
        for node, actual_path, replacement in targets:
            if node.start < previous_end:
                raise RewriteError("多个替换项定位到重复或父子重叠的字段")
            previous_end = node.end
            if equal(node, replacement.root):
                continue
            new_bytes = replacement.data[replacement.root.start:replacement.root.end]
            output_size += len(new_bytes) - (node.end - node.start)
            if output_size > BODY_LIMIT:
                raise RewriteError("改写后正文超过 1 MB 上限")
            changes.append({"path": concrete_path(actual_path), "originalJSON": document.raw(node), "replacementJSON": new_bytes.decode("utf-8")})
            replacements.append((node.start, node.end, new_bytes))
        if len(json.dumps(changes, ensure_ascii=True, separators=(",", ":")).encode("utf-8")) > BODY_LIMIT:
            raise RewriteError("修改记录超过 1 MB 上限")
        # Building once avoids quadratic copies for arrays with many matches.
        chunks, lower = [], 0
        for start, end, value in replacements:
            chunks.extend((data[lower:start], value))
            lower = end
        chunks.append(data[lower:])
        return b"".join(chunks), changes


class Settings:
    def __init__(self, value=None):
        value = value or {"schemaVersion": 1, "revision": 0, "enabled": False, "rules": []}
        if value.get("schemaVersion") != 1 or type(value.get("revision")) is not int or value["revision"] < 0:
            raise RewriteError("响应改写配置版本无效")
        self.revision = value["revision"]
        self.enabled = value.get("enabled", False)
        if not isinstance(self.enabled, bool):
            raise RewriteError("响应改写开关无效")
        sources = value.get("rules", [])
        if not isinstance(sources, list) or len(sources) > 100:
            raise RewriteError("每个项目最多保存 100 条响应改写规则")
        self.rules = tuple(Rule(rule, self.revision) for rule in sources)
        if len({rule.id for rule in self.rules}) != len(self.rules):
            raise RewriteError("规则 ID 重复")

    def candidates(self, method, url):
        return tuple(rule for rule in self.rules if rule.enabled and rule.matches_headers(method, url)) if self.enabled else ()


def save_artifact(directory, rule, original, original_headers, changes):
    """Write audit data before committing a response. Caller uses a bounded worker."""
    artifact_id = str(uuid.uuid4()).upper()
    value = {"schemaVersion": 1, "ruleID": rule.id, "ruleName": rule.name,
             "revision": rule.revision, "originalBody": base64.b64encode(original).decode("ascii"),
             "originalHeaders": original_headers, "changes": changes}
    data = json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    if len(data) > ARTIFACT_LIMIT:
        raise RewriteError("改写记录超过缓存上限")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink():
        raise RewriteError("改写缓存目录无效")
    if shutil.disk_usage(directory).free < 512 * 1024 * 1024 + len(data):
        raise RewriteError("磁盘剩余空间不足，未执行改写")
    temporary = directory / (artifact_id + ".tmp")
    destination = directory / (artifact_id + ".json")
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return artifact_id
