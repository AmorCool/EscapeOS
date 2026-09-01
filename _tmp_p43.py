import io

def patch(path, old, new, count=1):
    s = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
    assert s.count(old) == count, (path, old[:60], s.count(old), s.count(old))
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new))

p = 'EscapeOS/Services/PiPKeepAliveService.swift'

# PiP 状态改由 delegate 回调驱动（NSNotification.Name 在 AVKit 里没有这两个名字）
patch(p,
'''        pipController = pip

        // PiP 状态跟踪
        NotificationCenter.default.addObserver(
            self, selector: #selector(pipStateChange),
            name: .AVPictureInPictureControllerDidStartPictureInPicture, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pipStateChange),
            name: .AVPictureInPictureControllerDidStopPictureInPicture, object: nil)
        return pipController
    }

    @objc private func pipStateChange() {
        DispatchQueue.main.async {
            self.isPiPActive = self.pipController?.pictureInPictureActive ?? false
        }
    }''',
'''        pipController = pip
        return pipController
    }''')

# isPictureInPictureActive（Swift 命名）
patch(p,
'''    @objc private func pipStateChange() {
        DispatchQueue.main.async {
            self.isPiPActive = self.pipController?.pictureInPictureActive ?? false
        }
    }''',
'''''')

print('PiP 通知/属性名修复完成')
