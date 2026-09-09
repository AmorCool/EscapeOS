// authappstore —— 上游 `pkg/appstore` 登录链路的忠实移植。源文件对照：
//   appstore_login.go / appstore_bag.go / constants.go / account.go / error.go
//   / machine_id.go / action_signer.go —— 逻辑逐行照抄；
// 差异仅两处（均为环境必需，不影响报文形态）：
//   1. keychain（byteness/keyring 走系统服务，iOS 沙盒没有）→ 内存 stub，
//      登录结果由调用方（Swift）持久化；
//   2. machine.MacAddress（读本机网卡）→ 由调用方经 cgo 传入（与 SAP 硬件
//      标识同源的 MAC 形态 guid，Swift 侧持久化的 ApplePackageDeviceIdentifier）。
package authappstore

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	gohttp "net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/majd/ipatool/v2/internal/sap"
)

// ─── constants.go ────────────────────────────────────────────────────────

const (
	FailureTypeInvalidCredentials       = "-5000"
	FailureTypePasswordTokenExpired     = "2034"
	FailureTypeSignInRequired           = "2042"
	FailureTypeLicenseNotFound          = "9610"
	FailureTypeTemporarilyUnavailable   = "2059"
	FailureTypeLicenseAlreadyExists     = "5002"
	FailureTypeDeviceVerificationFailed = "1008"

	CustomerMessageBadLogin             = "MZFinance.BadLogin.Configurator_message"
	CustomerMessageAccountDisabled      = "Your account is disabled."
	CustomerMessageSubscriptionRequired = "Subscription Required"
	CustomerMessagePasswordChanged      = "Your password has changed."

	iTunesAPIDomain     = "itunes.apple.com"
	iTunesAPIPathSearch = "/search"
	iTunesAPIPathLookup = "/lookup"

	PrivateInitDomain = "init." + iTunesAPIDomain
	PrivateInitPath   = "/bag.xml"

	PrivateAppStoreAPIDomain       = "buy." + iTunesAPIDomain
	PrivateAppStoreAPIPathAuth     = "/WebObjects/MZFinance.woa/wa/authenticate"
	PrivateAppStoreAPIPathPurchase = "/WebObjects/MZFinance.woa/wa/buyProduct"
	PrivateAppStoreAPIPathDownload = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"

	PrivatePurchaseDAAPBaseURL = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"

	HTTPHeaderStoreFront = "X-Set-Apple-Store-Front"
	HTTPHeaderPod        = "pod"
)

// ─── account.go ──────────────────────────────────────────────────────────

type Account struct {
	Email               string `json:"email,omitempty"`
	PasswordToken       string `json:"passwordToken,omitempty"`
	DirectoryServicesID string `json:"directoryServicesIdentifier,omitempty"`
	Name                string `json:"name,omitempty"`
	StoreFront          string `json:"storeFront,omitempty"`
	Password            string `json:"password,omitempty"`
	Pod                 string `json:"pod,omitempty"`
}

// ─── error.go ────────────────────────────────────────────────────────────

type Error struct {
	Metadata        interface{}
	underlyingError error
}

func (t Error) Error() string {
	return t.underlyingError.Error()
}

func NewErrorWithMetadata(err error, metadata interface{}) *Error {
	return &Error{
		underlyingError: err,
		Metadata:        metadata,
	}
}

// ─── machine_id.go ───────────────────────────────────────────────────────

func machineIdentity(macAddress string) (string, []byte, error) {
	// 上游用 net.ParseMAC 解析 "aa:bb:cc:dd:ee:ff" 形态；调用方（Swift）持有的
	// ApplePackageDeviceIdentifier 已经是大写 hex 串（如 4C10888F7187），此处
	// 直接接受 hex 串并校验长度（1-20 字节，与上游规则一致）。
	hexStr := strings.ToLower(strings.ReplaceAll(macAddress, ":", ""))
	hardwareAddress, err := hex.DecodeString(hexStr)
	if err != nil {
		return "", nil, fmt.Errorf("failed to parse mac address: %w", err)
	}

	if len(hardwareAddress) == 0 || len(hardwareAddress) > 20 {
		return "", nil, fmt.Errorf("hardware address must contain between 1 and 20 bytes, got %d", len(hardwareAddress))
	}

	machineID := append([]byte(nil), hardwareAddress...)
	guid := strings.ToUpper(hex.EncodeToString(machineID))

	return guid, machineID, nil
}

// ─── action_signer.go ────────────────────────────────────────────────────

type SAPConfig struct {
	AuthEndpoint   string
	SetupURL       string
	CertificateURL string
	Version        uint32
}

type ActionSigner interface {
	httpActionSigner
	Close() error
}

// defaultActionSignerFactory 与上游一致：直接装配 internal/sap 的 Unicorn 签名器
//（CommerceKit x86-64 guest，资产包与宿主 SAP 签名共用同一份 cacheDir 缓存）.
func defaultActionSignerFactory(config SAPConfig, machineID []byte, cacheDir string) (ActionSigner, error) {
	signer, err := sap.NewSigner(context.Background(), sap.Config{
		SetupURL:       config.SetupURL,
		CertificateURL: config.CertificateURL,
		Version:        config.Version,
		HardwareID:     machineID,
		CacheDir:       cacheDir,
	})
	if err != nil {
		return nil, fmt.Errorf("create SAP signer: %w", err)
	}

	return signer, nil
}

// ─── appstore_bag.go ─────────────────────────────────────────────────────

type BagOutput struct {
	AuthEndpoint string
	SAPConfig    SAPConfig
}

func bag(guid string, bagClient Client[bagResult]) (BagOutput, error) {
	req := bagRequest(guid)

	res, err := bagClient.Send(req)
	if err != nil {
		return BagOutput{}, fmt.Errorf("failed to send http request: %w", err)
	}

	if res.StatusCode != gohttp.StatusOK {
		return BagOutput{}, fmt.Errorf("received unexpected status code: %d", res.StatusCode)
	}

	version, err := strconv.ParseUint(res.Data.URLBag.SAPVersion, 10, 32)
	if err != nil {
		return BagOutput{}, fmt.Errorf("invalid SAP version %q in bag: %w", res.Data.URLBag.SAPVersion, err)
	}

	config := SAPConfig{
		AuthEndpoint:   res.Data.URLBag.AuthEndpoint,
		SetupURL:       res.Data.URLBag.SAPSetupEndpoint,
		CertificateURL: res.Data.URLBag.SAPSetupCertEndpoint,
		Version:        uint32(version),
	}
	if err := validateSAPConfig(config); err != nil {
		return BagOutput{}, err
	}

	return BagOutput{AuthEndpoint: config.AuthEndpoint, SAPConfig: config}, nil
}

type bagResult struct {
	URLBag urlBag `plist:"urlBag,omitempty"`
}

type urlBag struct {
	AuthEndpoint         string `plist:"authenticateAccount,omitempty"`
	SAPSetupEndpoint     string `plist:"sign-sap-setup,omitempty"`
	SAPSetupCertEndpoint string `plist:"sign-sap-setup-cert,omitempty"`
	SAPVersion           string `plist:"sign-sap-version,omitempty"`
}

func validateSAPConfig(config SAPConfig) error {
	if err := validateAuthenticationEndpoint(config.AuthEndpoint); err != nil {
		return err
	}

	endpoints := []struct {
		name string
		url  string
	}{
		{name: "SAP setup", url: config.SetupURL},
		{name: "SAP setup certificate", url: config.CertificateURL},
	}

	for _, endpoint := range endpoints {
		parsed, err := url.ParseRequestURI(endpoint.url)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
			return fmt.Errorf("invalid %s endpoint %q in bag", endpoint.name, endpoint.url)
		}
	}

	if config.Version != 200 {
		return fmt.Errorf("unsupported SAP version %d in bag", config.Version)
	}

	return nil
}

func validateAuthenticationEndpoint(endpoint string) error {
	parsed, err := url.ParseRequestURI(endpoint)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return fmt.Errorf("invalid authentication endpoint %q", endpoint)
	}

	host := strings.ToLower(parsed.Hostname())
	if host != PrivateAppStoreAPIDomain && !strings.HasSuffix(host, "-buy.itunes.apple.com") {
		return fmt.Errorf("unsupported authentication endpoint %q", endpoint)
	}

	if parsed.Path != PrivateAppStoreAPIPathAuth {
		return fmt.Errorf("unsupported authentication endpoint %q", endpoint)
	}

	return nil
}

func bagRequest(guid string) Request {
	return Request{
		URL:            fmt.Sprintf("https://%s%s?guid=%s", PrivateInitDomain, PrivateInitPath, guid),
		Method:         MethodGET,
		ResponseFormat: ResponseFormatXML,
		Headers: map[string]string{
			"Accept": "application/xml",
		},
	}
}

// ─── appstore_login.go ───────────────────────────────────────────────────

var ErrAuthCodeRequired = errors.New("auth code is required")

const (
	maxAuthenticationRequestAttempts = 3
	authenticationRetryDelay         = 250 * time.Millisecond
)

type loginAddressResult struct {
	FirstName string `plist:"firstName,omitempty"`
	LastName  string `plist:"lastName,omitempty"`
}

type loginAccountResult struct {
	Email   string             `plist:"appleId,omitempty"`
	Address loginAddressResult `plist:"address,omitempty"`
}

type loginResult struct {
	FailureType         string             `plist:"failureType,omitempty"`
	CustomerMessage     string             `plist:"customerMessage,omitempty"`
	Account             loginAccountResult `plist:"accountInfo,omitempty"`
	DirectoryServicesID string             `plist:"dsPersonId,omitempty"`
	PasswordToken       string             `plist:"passwordToken,omitempty"`
}

// login 执行一次完整登录（bag → SAP 签名器 → 双层重试 → 解析 → Account）。
// cacheDir 传宿主 Caches 目录（SAP 资产包缓存，与 Swift 侧 SapSigner 共用）。
// 第三返回值是登录会话 cookie（download/purchase 等下游请求的会话延续需要，
// Swift 侧并入 AppStoreAccount.cookie 持久化）。
func Login(email, password, authCode, macAddress, cacheDir string) (Account, []SessionCookie, error) {
	guid, machineID, err := machineIdentity(macAddress)
	if err != nil {
		return Account{}, nil, err
	}

	jar := newJarWithSave()
	bagClient := NewClient[bagResult](Args{CookieJar: jar})

	bag, err := bag(guid, bagClient)
	if err != nil {
		return Account{}, nil, fmt.Errorf("failed to get bag: %w", err)
	}

	signer, err := defaultActionSignerFactory(bag.SAPConfig, machineID, cacheDir)
	if err != nil {
		return Account{}, nil, fmt.Errorf("failed to initialize SAP action signer: %w", err)
	}

	acc, loginErr := performLogin(email, password, authCode, guid, bag.SAPConfig.AuthEndpoint, signer, jar)
	closeErr := signer.Close()

	if closeErr != nil {
		closeErr = fmt.Errorf("failed to close SAP action signer: %w", closeErr)
	}

	if loginErr != nil {
		if closeErr != nil {
			return Account{}, nil, errors.Join(loginErr, closeErr)
		}

		return Account{}, nil, loginErr
	}

	if closeErr != nil {
		return acc, sessionCookies(jar), closeErr
	}

	return acc, sessionCookies(jar), nil
}

// SessionCookie 是导出给宿主（Swift）的会话 cookie 快照.
type SessionCookie struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	Domain string `json:"domain"`
	Path   string `json:"path"`
}

func sessionCookies(jar *jarWithSave) []SessionCookie {
	out := make([]SessionCookie, 0, 8)
	for _, host := range []string{"buy.itunes.apple.com", "auth.itunes.apple.com", "init.itunes.apple.com"} {
		u, err := url.Parse("https://" + host + "/")
		if err != nil {
			continue
		}

		for _, ck := range jar.Cookies(u) {
			out = append(out, SessionCookie{
				Name:   ck.Name,
				Value:  ck.Value,
				Domain: host,
				Path:   ck.Path,
			})
		}
	}

	return out
}

func performLogin(email, password, authCode, guid, endpoint string, signer ActionSigner, jar *jarWithSave) (Account, error) {
	redirect := ""

	var (
		err error
		res Result[loginResult]
	)

	retry := true

	loginClient := NewClient[loginResult](Args{CookieJar: jar})

	for attempt := 1; retry && attempt <= 4; attempt++ {
		requestAttempt := attempt
		if redirect != "" {
			// The pod redirect is part of the same authentication attempt. Apple
			// expects the original XML plist body, including its attempt value.
			requestAttempt = 1
		}

		request := loginRequest(email, password, authCode, guid, endpoint, requestAttempt, signer)
		request.URL, _ = IfEmpty(redirect, request.URL), ""
		res, err = sendAuthenticationRequest(loginClient, request)

		if err != nil {
			return Account{}, fmt.Errorf("request failed: %w", err)
		}

		if retry, redirect, err = parseLoginResponse(&res, attempt, authCode); err != nil {
			return Account{}, err
		}
	}

	if retry {
		return Account{}, NewErrorWithMetadata(errors.New("too many attempts"), res)
	}

	sf, err := res.GetHeader(HTTPHeaderStoreFront)
	if err != nil {
		return Account{}, NewErrorWithMetadata(fmt.Errorf("failed to get storefront header: %w", err), res)
	}

	pod, err := res.GetHeader(HTTPHeaderPod)
	if err != nil && !errors.Is(err, ErrHeaderNotFound) {
		return Account{}, NewErrorWithMetadata(fmt.Errorf("failed to get pod header: %w", err), res)
	}

	addr := res.Data.Account.Address
	acc := Account{
		Name:                strings.Join([]string{addr.FirstName, addr.LastName}, " "),
		Email:               res.Data.Account.Email,
		PasswordToken:       res.Data.PasswordToken,
		DirectoryServicesID: res.Data.DirectoryServicesID,
		StoreFront:          sf,
		Password:            password,
		Pod:                 pod,
	}

	return acc, nil
}

func sendAuthenticationRequest(loginClient Client[loginResult], request Request) (Result[loginResult], error) {
	statuses := make([]string, 0, maxAuthenticationRequestAttempts)

	for attempt := 1; ; attempt++ {
		result, err := loginClient.Send(request)

		status, retry := retryableAuthenticationError(err)
		if !retry {
			if err != nil {
				return result, fmt.Errorf("%w", err)
			}

			return result, nil
		}

		statuses = append(statuses, strconv.Itoa(status))

		if attempt == maxAuthenticationRequestAttempts {
			return result, fmt.Errorf(
				"authentication request failed after %d attempts (HTTP %s): %w",
				maxAuthenticationRequestAttempts, strings.Join(statuses, ", "), err,
			)
		}

		time.Sleep(time.Duration(attempt) * authenticationRetryDelay)
	}
}

func retryableAuthenticationError(err error) (int, bool) {
	var responseErr *UnexpectedResponseError
	if !errors.As(err, &responseErr) {
		return 0, false
	}

	status := responseErr.StatusCode
	retry := status == gohttp.StatusNoContent ||
		status == gohttp.StatusNotFound ||
		status/100 == 5

	return status, retry
}

func parseLoginResponse(res *Result[loginResult], attempt int, authCode string) (bool, string, error) {
	var (
		retry    bool
		redirect string
		err      error
	)

	if res.StatusCode == gohttp.StatusFound {
		if redirect, err = res.GetHeader("location"); err != nil {
			err = fmt.Errorf("failed to retrieve redirect location: %w", err)
		} else if err = validateAuthenticationEndpoint(redirect); err != nil {
			err = fmt.Errorf("invalid authentication redirect: %w", err)
		} else {
			retry = true
		}
	} else if attempt == 1 && res.Data.FailureType == FailureTypeInvalidCredentials {
		retry = true
	} else if res.Data.FailureType == "" && authCode == "" && res.Data.CustomerMessage == CustomerMessageBadLogin {
		err = ErrAuthCodeRequired
	} else if res.Data.FailureType == "" && res.Data.CustomerMessage == CustomerMessageAccountDisabled {
		err = NewErrorWithMetadata(errors.New("account is disabled"), res)
	} else if res.Data.FailureType != "" {
		if res.Data.CustomerMessage != "" {
			err = NewErrorWithMetadata(errors.New(res.Data.CustomerMessage), res)
		} else {
			err = NewErrorWithMetadata(errors.New("something went wrong"), res)
		}
	} else if res.StatusCode != gohttp.StatusOK || res.Data.PasswordToken == "" || res.Data.DirectoryServicesID == "" {
		err = NewErrorWithMetadata(errors.New("something went wrong"), res)
	}

	return retry, redirect, err
}

func loginRequest(email, password, authCode, guid, endpoint string, attempt int, signer ActionSigner) Request {
	return Request{
		Method:         MethodPOST,
		URL:            endpoint,
		ResponseFormat: ResponseFormatXML,
		ActionSigner:   signer,
		Headers: map[string]string{
			"Content-Type": "application/x-www-form-urlencoded",
		},
		Payload: &XMLPayload{
			Content: map[string]interface{}{
				"appleId":  email,
				"attempt":  strconv.Itoa(attempt),
				"guid":     guid,
				"password": fmt.Sprintf("%s%s", password, strings.ReplaceAll(authCode, " ", "")),
				"rmp":      "0",
				"why":      "signIn",
			},
		},
	}
}

// IfEmpty —— 上游 pkg/util/string.go 原样内联（避免为一个 5 行函数引入包依赖）.
func IfEmpty(value, fallback string) string {
	if value == "" {
		return fallback
	}

	return value
}
