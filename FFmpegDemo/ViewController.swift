//
//  ViewController.swift
//  FFmpegDemo
//

import UIKit

class ViewController: UIViewController {

    let textView: UITextView = {
        let tv = UITextView()
        tv.font = UIFont.systemFont(ofSize: 16)
        tv.layer.borderColor = UIColor.gray.cgColor
        tv.layer.borderWidth = 1
        tv.layer.cornerRadius = 8
      //  tv.text = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
        
        tv.text = "http://devimages.apple.com/iphone/samples/bipbop/bipbopall.m3u8"
        return tv
    }()

    let button1: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("FFmpeg+ImageView", for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        btn.titleLabel?.adjustsFontSizeToFitWidth = true
        btn.backgroundColor = .systemBlue
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 8
        return btn
    }()

    let button2: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("FFmpeg+AVSampleBufferDisplayLayer", for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        btn.backgroundColor = .systemGreen
        btn.titleLabel?.adjustsFontSizeToFitWidth = true
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 8
        return btn
    }()

    let button3: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("FFmpeg+VideoToolBox+时间对其", for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        btn.backgroundColor = .systemOrange
        btn.titleLabel?.adjustsFontSizeToFitWidth = true
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 8
        return btn
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        view.addSubview(textView)
        view.addSubview(button1)
        view.addSubview(button2)
        view.addSubview(button3)

        textView.translatesAutoresizingMaskIntoConstraints = false
        button1.translatesAutoresizingMaskIntoConstraints = false
        button2.translatesAutoresizingMaskIntoConstraints = false
        button3.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textView.heightAnchor.constraint(equalToConstant: 150),

            button1.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 20),
            button1.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button1.widthAnchor.constraint(equalToConstant: 300),
            button1.heightAnchor.constraint(equalToConstant: 50),

            button2.topAnchor.constraint(equalTo: button1.bottomAnchor, constant: 15),
            button2.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button2.widthAnchor.constraint(equalToConstant: 300),
            button2.heightAnchor.constraint(equalToConstant: 50),

            button3.topAnchor.constraint(equalTo: button2.bottomAnchor, constant: 15),
            button3.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button3.widthAnchor.constraint(equalToConstant: 300),
            button3.heightAnchor.constraint(equalToConstant: 50),
        ])

        button1.addTarget(self, action: #selector(openVC1), for: .touchUpInside)
        button2.addTarget(self, action: #selector(openVC2), for: .touchUpInside)
        button3.addTarget(self, action: #selector(openVC3), for: .touchUpInside)
    }

    @objc func openVC1() {
        let vc = FFmpegPlayerViewController()
        vc.urlString = textView.text
        present(vc, animated: true)
    }

    @objc func openVC2() {
        let vc = FFmpegSampleBufferPlayerViewController()
        vc.urlString = textView.text
        present(vc, animated: true)
    }

    @objc func openVC3() {
        let vc = FFmpegVTPlayerViewController() 
        vc.urlString = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
        present(vc, animated: true)
    }
}
