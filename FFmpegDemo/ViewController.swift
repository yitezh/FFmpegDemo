//
//  ViewController.swift
//  FFmpegDemo
//
//  Created by yite on 2026/2/4.
//

import UIKit

class ViewController: UIViewController {

    let textView: UITextView = {
        let tv = UITextView()
        tv.font = UIFont.systemFont(ofSize: 16)
        tv.layer.borderColor = UIColor.gray.cgColor
        tv.layer.borderWidth = 1
        tv.layer.cornerRadius = 8
        //默认只支持http，如果要支持https需要加入配置重新打包FFmpeg
        tv.text = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
        return tv
    }()

    let confirmButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("播放", for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        btn.backgroundColor = .systemBlue
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 8
        return btn
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        view.addSubview(textView)
        view.addSubview(confirmButton)

        textView.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textView.heightAnchor.constraint(equalToConstant: 150),

            confirmButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 20),
            confirmButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            confirmButton.widthAnchor.constraint(equalToConstant: 100),
            confirmButton.heightAnchor.constraint(equalToConstant: 50)
        ])

        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
    }

    @objc func confirmTapped() {
        let ffmpegVC = FFmpegSampleBufferPlayerViewController()
        ffmpegVC.urlString = textView.text
        self.present(ffmpegVC, animated: true)
    }

}

