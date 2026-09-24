#pragma once
// Xcode 27 兼容（2026-09-18）：本头文件用到 `set<string>` / `string`，
//   此前依赖 `mach-o.h` → `openssl.h` → `json.h` 的**传递包含**（json.h 里有 <string> 但**没有 <set>**）。
//   Xcode 27 的新 libc++ 不再传递提供这些符号，会报 `error: no template named 'set'`。
//   ⇒ 按「头文件自包含」原则显式补上。**不要删**。
#include <set>
#include <string>
#include "mach-o.h"
#include "openssl.h"

class ZArchO
{
public:
	ZArchO();

public:
	bool Init(uint8_t* pBase, uint32_t uLength);

public:
	bool Sign(ZSignAsset* pSignAsset, 
				bool bForce, 
				const string& strBundleId, 
				const string& strInfoSHA1, 
				const string& strInfoSHA256, 
				const string& strCodeResourcesData);

	void PrintInfo();
	bool IsExecute();
	bool InjectDylib(bool bWeakInject, const char* szDylibFile);
	void RemoveDylibs(set<string> setDylibs);
	uint32_t ReallocCodeSignSpace(const string& strNewFile);

private:
	uint32_t	BO(uint32_t uVal);
	const char* GetFileType(uint32_t uFileType);
	const char* GetArch(int cpuType, int cpuSubType);
	bool		BuildCodeSignature(ZSignAsset* pSignAsset, 
									bool bForce, 
									const string& strBundleId, 
									const string& strInfoSHA1, 
									const string& strInfoSHA256,
									const string& strCodeResourcesSHA1, 
									const string& strCodeResourcesSHA256, 
									string& strOutput);

public:
	uint8_t*		m_pBase;
	uint32_t		m_uLength;
	uint32_t		m_uCodeLength;
	uint8_t*		m_pSignBase;
	uint32_t		m_uSignLength;
	string			m_strInfoPlist;
	bool			m_bEncrypted;
	bool			m_b64Bit;
	bool			m_bBigEndian;
	bool			m_bEnoughSpace;
	uint8_t*		m_pCodeSignSegment;
	uint8_t*		m_pLinkEditSegment;
	uint32_t		m_uLoadCommandsFreeSpace;
	uint32_t		m_uFileType;
	mach_header*	m_pHeader;
	uint32_t		m_uHeaderSize;
	uint64_t		m_uExecSegLimit;
};
