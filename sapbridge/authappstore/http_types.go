// authappstore —— 上游 `pkg/http` 的 request.go / payload.go / result.go /
// constants.go / method.go / cookiejar.go 文件级照抄（仅合并包名）。
// jarWithSave 是唯一新增：标准库 cookiejar + 空 Save()（上游 CookieJar 接口
// 要求 Save，持久化实现用文件/keyring；iOS 登录无状态化，cookie 经返回值交
// Swift 持久化，无需落盘）。
package authappstore

import (
	"bytes"
	"errors"
	"fmt"
	gohttp "net/http"
	"net/http/cookiejar"
	"net/url"
	"strconv"
	"strings"

	"howett.net/plist"
)

// ─── request.go ──────────────────────────────────────────────────────────

type Request struct {
	Method         string
	URL            string
	Headers        map[string]string
	Payload        Payload
	ActionSigner   ActionSigner
	ResponseFormat ResponseFormat
}

// httpActionSigner 即上游 pkg/http.ActionSigner（改名避免与 authappstore 内
// 带 Close 的 ActionSigner 冲突，接口形状逐字节一致）。
type httpActionSigner interface {
	Sign(data []byte) ([]byte, error)
}

// ─── payload.go ──────────────────────────────────────────────────────────

type Payload interface {
	data() ([]byte, error)
}

type XMLPayload struct {
	Content map[string]interface{}
}

type URLPayload struct {
	Content map[string]interface{}
}

// RawPayload sends Content without applying an encoding. It is used by Apple
// services whose request body is already serialized, such as DAAP/DMAP.
type RawPayload struct {
	Content []byte
}

func (p *XMLPayload) data() ([]byte, error) {
	buffer := new(bytes.Buffer)

	err := plist.NewEncoder(buffer).Encode(p.Content)
	if err != nil {
		return nil, fmt.Errorf("failed to encode plist: %w", err)
	}

	return buffer.Bytes(), nil
}

func (p *URLPayload) data() ([]byte, error) {
	params := url.Values{}

	for key, val := range p.Content {
		switch t := val.(type) {
		case string:
			params.Add(key, val.(string))
		case int:
			params.Add(key, strconv.Itoa(val.(int)))
		default:
			return nil, fmt.Errorf("value type is not supported (%s)", t)
		}
	}

	return []byte(params.Encode()), nil
}

func (p *RawPayload) data() ([]byte, error) {
	return append([]byte(nil), p.Content...), nil
}

// ─── constants.go ────────────────────────────────────────────────────────

type ResponseFormat string

const (
	ResponseFormatJSON ResponseFormat = "json"
	ResponseFormatRaw  ResponseFormat = "raw"
	ResponseFormatXML  ResponseFormat = "xml"
)

const (
	DefaultUserAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

	HeaderAppleActionSignature = "X-Apple-ActionSignature"
)

// ─── method.go ───────────────────────────────────────────────────────────

const (
	MethodGET  = "GET"
	MethodPOST = "POST"
)

// ─── result.go ───────────────────────────────────────────────────────────

var ErrHeaderNotFound = errors.New("header not found")

type Result[R interface{}] struct {
	StatusCode int
	Headers    map[string]string
	Data       R
}

func (c *Result[R]) GetHeader(key string) (string, error) {
	key = strings.ToLower(key)
	for k, v := range c.Headers {
		if strings.ToLower(k) == key {
			return v, nil
		}
	}

	return "", ErrHeaderNotFound
}

// ─── cookiejar.go ────────────────────────────────────────────────────────

type CookieJar interface {
	gohttp.CookieJar

	Save() error
}

type jarWithSave struct {
	*cookiejar.Jar
}

func newJarWithSave() *jarWithSave {
	jar, err := cookiejar.New(nil)
	if err != nil {
		// cookiejar.New(nil) 永不返回错误（nil options 合法）；防御性兜底.
		panic(fmt.Sprintf("cookiejar.New: %v", err))
	}

	return &jarWithSave{Jar: jar}
}

func (j *jarWithSave) Save() error { return nil }
