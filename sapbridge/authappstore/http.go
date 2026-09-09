// Package authappstore — 上游 majd/ipatool v2 `pkg/http` 的忠实移植（文件级照抄，
// 仅改包名）。登录请求的报文形态（头集合/顺序、Content-Type、Go 标准库 TLS 栈）
// 与 IPARanger 捆绑的 ipatool 二进制完全一致 —— 这是本包存在的意义：
// EscapeOS 旧 Swift 登录链路被 Apple 边缘 WAF 秒拒（真机 2026-09-09 18:23 日志：
// 0.4s HTML 404/403，蜂窝亦然），而同网络下 Go 栈的 ipatool 形态可用。
//
// 源文件对照（upstream = github.com/majd/ipatool/v2 @ main, 2026-09）：
//   client.go / request.go / payload.go / result.go / constants.go / method.go
//   / cookiejar.go —— 逐文件照抄；keyring 依赖未引入（CookieJar 由调用方注入）。
package authappstore

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	gohttp "net/http"
	"regexp"
	"strings"

	"howett.net/plist"
)

const appStoreAuthPath = "/WebObjects/MZFinance.woa/wa/authenticate"

var (
	documentXMLPattern = regexp.MustCompile(`(?is)<Document\b[^>]*>(.*)</Document>`)
	plistXMLPattern    = regexp.MustCompile(`(?is)<plist\b[^>]*>.*?</plist>`)
	dictXMLPattern     = regexp.MustCompile(`(?is)<dict\b[^>]*>.*</dict>`)
	htmlTagPattern     = regexp.MustCompile(`(?is)<[^>]*>`)
)

type Client[R interface{}] interface {
	Send(request Request) (Result[R], error)
	Do(req *gohttp.Request) (*gohttp.Response, error)
	NewRequest(method, url string, body io.Reader) (*gohttp.Request, error)
}

type client[R interface{}] struct {
	internalClient gohttp.Client
	cookieJar      CookieJar
}

type Args struct {
	CookieJar CookieJar
}

// UnexpectedResponseError preserves the HTTP status when Apple returns an
// HTML or empty response where an XML plist was expected.
type UnexpectedResponseError struct {
	StatusCode int
	Snippet    string
}

func (e *UnexpectedResponseError) Error() string {
	if e.Snippet == "" {
		return fmt.Sprintf("unexpected response from Apple (HTTP %d): empty or non-plist body", e.StatusCode)
	}

	return fmt.Sprintf("unexpected response from Apple (HTTP %d): %s", e.StatusCode, e.Snippet)
}

type AddHeaderTransport struct {
	T gohttp.RoundTripper
}

func (t *AddHeaderTransport) RoundTrip(req *gohttp.Request) (*gohttp.Response, error) {
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", DefaultUserAgent)
	}

	res, err := t.T.RoundTrip(req)
	if err != nil {
		return nil, fmt.Errorf("failed to make round trip: %w", err)
	}

	return res, nil
}

func NewClient[R interface{}](args Args) Client[R] {
	return &client[R]{
		internalClient: gohttp.Client{
			Timeout: 0,
			Jar:     args.CookieJar,
			CheckRedirect: func(req *gohttp.Request, via []*gohttp.Request) error {
				if len(via) > 0 && via[len(via)-1].URL.Path == appStoreAuthPath {
					return gohttp.ErrUseLastResponse
				}

				return nil
			},
			Transport: &AddHeaderTransport{gohttp.DefaultTransport},
		},
		cookieJar: args.CookieJar,
	}
}

func (c *client[R]) Send(req Request) (Result[R], error) {
	var (
		data []byte
		err  error
	)

	if req.Payload != nil {
		data, err = req.Payload.data()
		if err != nil {
			return Result[R]{}, fmt.Errorf("failed to get payload data: %w", err)
		}
	}

	request, err := gohttp.NewRequest(req.Method, req.URL, bytes.NewReader(data))
	if err != nil {
		return Result[R]{}, fmt.Errorf("failed to create request: %w", err)
	}

	for key, val := range req.Headers {
		request.Header.Set(key, val)
	}

	if req.ActionSigner != nil {
		signature, err := req.ActionSigner.Sign(data)
		if err != nil {
			return Result[R]{}, fmt.Errorf("failed to sign Apple action: %w", err)
		}

		request.Header.Set(HeaderAppleActionSignature, base64.StdEncoding.EncodeToString(signature))
	}

	res, err := c.internalClient.Do(request)
	if err != nil {
		return Result[R]{}, fmt.Errorf("request failed: %w", err)
	}
	defer res.Body.Close()

	err = c.cookieJar.Save()
	if err != nil {
		return Result[R]{}, fmt.Errorf("failed to save cookies: %w", err)
	}

	if req.ResponseFormat == ResponseFormatJSON {
		return c.handleJSONResponse(res)
	}

	if req.ResponseFormat == ResponseFormatRaw {
		return c.handleRawResponse(res)
	}

	if req.ResponseFormat == ResponseFormatXML {
		return c.handleXMLResponse(res)
	}

	return Result[R]{}, fmt.Errorf("content type is not supported (%s)", req.ResponseFormat)
}

func (c *client[R]) handleRawResponse(res *gohttp.Response) (Result[R], error) {
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return Result[R]{}, fmt.Errorf("failed to read response body: %w", err)
	}

	data, ok := any(body).(R)
	if !ok {
		return Result[R]{}, errors.New("raw response format requires a []byte result type")
	}

	return Result[R]{
		StatusCode: res.StatusCode,
		Headers:    responseHeaders(res),
		Data:       data,
	}, nil
}

func (c *client[R]) Do(req *gohttp.Request) (*gohttp.Response, error) {
	res, err := c.internalClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("received error: %w", err)
	}

	return res, nil
}

func (*client[R]) NewRequest(method, url string, body io.Reader) (*gohttp.Request, error) {
	req, err := gohttp.NewRequest(method, url, body)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	return req, nil
}

func (c *client[R]) handleJSONResponse(res *gohttp.Response) (Result[R], error) {
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return Result[R]{}, fmt.Errorf("failed to read response body: %w", err)
	}

	var data R

	err = json.Unmarshal(body, &data)
	if err != nil {
		return Result[R]{}, fmt.Errorf("failed to unmarshal json: %w", err)
	}

	return Result[R]{
		StatusCode: res.StatusCode,
		Data:       data,
	}, nil
}

func (c *client[R]) handleXMLResponse(res *gohttp.Response) (Result[R], error) {
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return Result[R]{}, fmt.Errorf("failed to read response body: %w", err)
	}

	if res.StatusCode == gohttp.StatusTooManyRequests {
		return Result[R]{}, fmt.Errorf("rate limited by Apple (HTTP %d): %s", res.StatusCode, strings.TrimSpace(string(body)))
	}

	// The legacy authentication endpoint redirects to an assigned Store pod.
	// Preserve the redirect response and its Location header so callers can
	// repeat the original POST request at that pod.
	if res.StatusCode >= gohttp.StatusMultipleChoices && res.StatusCode < gohttp.StatusBadRequest {
		return Result[R]{
			StatusCode: res.StatusCode,
			Headers:    responseHeaders(res),
		}, nil
	}

	var data R

	normalizedBody := normalizeXMLPlistBody(body)

	if !looksLikePropertyList(normalizedBody) {
		snippet := bodySnippet(body)

		return Result[R]{}, &UnexpectedResponseError{
			StatusCode: res.StatusCode,
			Snippet:    snippet,
		}
	}

	_, err = plist.Unmarshal(normalizedBody, &data)
	if err != nil {
		return Result[R]{}, fmt.Errorf("failed to unmarshal xml: %w", err)
	}

	return Result[R]{
		StatusCode: res.StatusCode,
		Headers:    responseHeaders(res),
		Data:       data,
	}, nil
}

func responseHeaders(res *gohttp.Response) map[string]string {
	headers := map[string]string{}
	for key, val := range res.Header {
		headers[key] = strings.Join(val, "; ")
	}

	return headers
}

func normalizeXMLPlistBody(body []byte) []byte {
	normalized := bytes.TrimSpace(body)
	if len(normalized) == 0 {
		return normalized
	}

	if documentBody := extractDocumentInnerBody(normalized); len(documentBody) > 0 {
		normalized = documentBody
	}

	if embeddedPlist := extractEmbeddedPlist(normalized); len(embeddedPlist) > 0 {
		normalized = embeddedPlist
	}

	if dictBody := extractEmbeddedDict(normalized); len(dictBody) > 0 {
		return dictBody
	}

	if bytes.Contains(normalized, []byte("<key>")) {
		return []byte("<dict>" + string(normalized) + "</dict>")
	}

	return normalized
}

// looksLikePropertyList reports whether body appears to be a (binary or XML)
// property list. Apple occasionally answers with an HTML error page or a plain
// text message; those must not be handed to plist.Unmarshal, which would
// misinterpret a leading "<h..." as an OpenStep hex-data block and fail with an
// opaque "unexpected hex digit" error instead of surfacing Apple's actual response.
func looksLikePropertyList(body []byte) bool {
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 {
		return false
	}

	if bytes.HasPrefix(trimmed, []byte("bplist")) {
		return true
	}

	lower := bytes.ToLower(trimmed)
	for _, marker := range [][]byte{
		[]byte("<?xml"),
		[]byte("<plist"),
		[]byte("<dict"),
		[]byte("<key"),
	} {
		if bytes.Contains(lower, marker) {
			return true
		}
	}

	return false
}

// bodySnippet returns a compact, single-line excerpt of a non-plist response
// body suitable for embedding in an error message. HTML markup is stripped so
// the underlying message (if any) is readable.
func bodySnippet(body []byte) string {
	text := htmlTagPattern.ReplaceAll(body, []byte(" "))
	snippet := strings.Join(strings.Fields(string(text)), " ")

	const maxLen = 200
	if len(snippet) > maxLen {
		snippet = snippet[:maxLen] + "…"
	}

	return snippet
}

func extractEmbeddedPlist(body []byte) []byte {
	plistMatch := plistXMLPattern.Find(body)
	if len(plistMatch) == 0 {
		return nil
	}

	return bytes.TrimSpace(plistMatch)
}

func extractEmbeddedDict(body []byte) []byte {
	dictMatch := dictXMLPattern.Find(body)
	if len(dictMatch) == 0 {
		return nil
	}

	return bytes.TrimSpace(dictMatch)
}

func extractDocumentInnerBody(body []byte) []byte {
	documentMatch := documentXMLPattern.FindSubmatch(body)
	if len(documentMatch) < 2 {
		return nil
	}

	documentBody := bytes.TrimSpace(documentMatch[1])
	if len(documentBody) == 0 {
		return nil
	}

	return documentBody
}
