## Linked issue

Closes #
<!-- 用 `Closes #NNN` 在合併時關閉 issue；若 issue 要保持開啟，改用
     `Relates to #NNN`。在內文中請寫成 `base#NNN`。 -->

## Single concern and atomic commits

- [ ] 這個 PR 只解決一個核心問題，沒有混入無關的重構或相依的變更。
- [ ] 如果工作有數個邏輯步驟，已整理成乾淨的原子 commit。

## Control flow

- [ ] 新增或修改的程式碼，控制流程巢狀最多 3 層。
- [ ] 前置條件與錯誤處理使用 guard clause（提早 return）來攤平程式碼，不使用箭頭形的巢狀。

## Test and build

- [ ] 映像檔可以建置（Docker build 與語法檢查通過）。
- [ ] 既有的測試矩陣（Bats 與單元測試）全部通過。

## Security and boundaries

- [ ] 容器維持非特權使用者的邊界，且沒有寫死主機專屬的絕對路徑。
