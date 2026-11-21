import XCTest
@testable import MolaCore

final class RoleTests: XCTestCase {
    func testSHA256() {
        XCTAssertEqual(SHA256.hexHash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hexHash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(SHA256.hmac(key: Array("key".utf8), message: Array("The quick brown fox jumps over the lazy dog".utf8))),
                       "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    }

    func testCardV2AndPNG() throws {
        let card = #"{"spec":"chara_card_v2","data":{"name":"艾琳","description":"{{char}} 是骑士","first_mes":"你好，{{user}}","alternate_greetings":["哟"],"mes_example":"<START>\n{{user}}: 你是谁\n{{char}}: 我是艾琳","extensions":{"depth_prompt":{"prompt":"保持骑士口吻","depth":2,"role":0}},"character_book":{"entries":[{"keys":["王都"],"content":"王都在北方","insertion_order":5,"extensions":{"position":1}}]}}}"#
        let r = try CharacterCardReader.read(json: Data(card.utf8))
        let p = try XCTUnwrap(r.persona.profile)
        XCTAssertEqual(r.persona.name, "艾琳")
        XCTAssertTrue(r.persona.isRolePlay)
        XCTAssertEqual(p.characterNoteDepth, 2)
        XCTAssertEqual(p.lorebooks.first?.entries.first?.keys, ["王都"])
        // 包成 PNG tEXt chunk 再读
        var png = Data(CharacterCardReader.pngSignature)
        let payload = Data("chara".utf8) + Data([0]) + Data(Data(card.utf8).base64EncodedString().utf8)
        var len = UInt32(payload.count).bigEndian
        png.append(Data(bytes: &len, count: 4)); png.append(Data("tEXt".utf8)); png.append(payload); png.append(Data(count: 4))
        XCTAssertEqual(try CharacterCardReader.read(png).persona.name, "艾琳")
        XCTAssertThrowsError(try CharacterCardReader.read(json: Data(#"{"spec":"other"}"#.utf8)))
    }

    func testLorebookAndPlan() throws {
        var e1 = LoreEntry(); e1.keys = ["王都"]; e1.content = "王都在北方"; e1.position = .afterCharacter
        var e2 = LoreEntry(); e2.constant = true; e2.content = "世界常识"; e2.position = .atDepth; e2.depth = 1
        var e3 = LoreEntry(); e3.keys = ["龙"]; e3.content = "龙已灭绝"
        var book = Lorebook(); book.entries = [e1, e2, e3]
        let hits = LorebookMatcher.evaluate(books: [book], messages: ["我们去王都吧"], interpolate: { $0 }, generationId: "g", sillyTavern: true, globalBudget: 2048)
        XCTAssertEqual(Set(hits.map(\.entry.content)), ["王都在北方", "世界常识"])

        var profile = PersonaProfile()
        profile.description = "{{char}} 是骑士"; profile.lorebooks = [book]; profile.compatibility = .sillytavern
        profile.exampleDialogue = "<START>\n{{user}}: 你是谁\n{{char}}: 我是艾琳"
        profile.postHistoryInstructions = "简短回答"
        let persona = Persona(name: "艾琳", systemPrompt: "扮演 {{char}}")
        let plan = RolePromptBuilder.build(persona: persona, profile: profile, conversationPrompt: nil, appendMode: false,
                                           userName: "小明", model: "m", provider: "p", history: ["去王都"], sharedBooks: [], generationId: "g")
        XCTAssertTrue(plan.system.hasPrefix("扮演 艾琳"))
        XCTAssertTrue(plan.system.contains("角色资料：\n艾琳 是骑士"))
        XCTAssertTrue(plan.system.contains("王都在北方"))
        XCTAssertEqual(plan.examples.map(\.role), [.user, .assistant])
        let wire = RolePromptBuilder.apply(plan, to: [.text(.user, "a"), .text(.assistant, "b"), .text(.user, "c")])
        XCTAssertEqual(wire.count, 2 + 3)
        XCTAssertTrue(wire.last!.text.contains("简短回答"))
        XCTAssertEqual(RolePromptBuilder.greetings(PersonaProfile(), persona: persona, userName: "x"), [])
    }
}
