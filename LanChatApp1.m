classdef LanChatApp1 < matlab.apps.AppBase
    % LANCHATAPP MATLAB局域网多人聊天App (1主机+无限N客机)
    % 适用版本: MATLAB R2021a 或更高
    % 已升级: UDP数据报协议突破了 TCP 的单人限制，支持无限人数并发连接
    
    % =====================================================================
    % 属性定义区域
    % =====================================================================
    properties (Access = public)
        UIFigure            % 主窗口
        MainGrid            % 主网格布局
        UserGrid            % 用户信息网格
        TopGrid             % 顶部控制区网格
        BottomGrid          % 底部输入区网格
        
        UserNameEdit        matlab.ui.control.EditField 
        
        % 左侧服务端组件
        ServerPanel         matlab.ui.container.Panel
        ServerPortEdit      matlab.ui.control.NumericEditField
        ServerStartBtn      matlab.ui.control.Button
        ServerStopBtn       matlab.ui.control.Button
        ServerStatusLabel   matlab.ui.control.Label
        
        % 右侧客户端组件
        ClientPanel         matlab.ui.container.Panel
        ClientIPEdit        matlab.ui.control.EditField
        ClientPortEdit      matlab.ui.control.NumericEditField
        ClientConnectBtn    matlab.ui.control.Button
        ClientDisconnBtn    matlab.ui.control.Button
        ClientStatusLabel   matlab.ui.control.Label
        
        % 聊天与输入组件
        ChatHistoryArea     matlab.ui.control.TextArea
        MessageInputField   matlab.ui.control.TextArea
        SendBtn             matlab.ui.control.Button
    end
    
    properties (Access = private)
        Server              % udpport 对象 (主机模式)
        Client              % udpport 对象 (客机模式)
        
        ConnectionMode      % 当前模式：'none', 'server', 'client'
        MyClientID          % 本机唯一标识符 UUID
        
        % --- UDP 多人路由核心字典 ---
        ConnectedClients    % 字典 (containers.Map)，记录所有连入客机的 IP 和 Port
        HostIP              % 客机专用：目标主机 IP
        HostPort            % 客机专用：目标主机 Port
    end
    
    % =====================================================================
    % 核心业务方法 (网络与通信)
    % =====================================================================
    methods (Access = private)
        
        %% 服务端（主机）逻辑：单端口，接纳无限人连入，承担广播路由
        function startServer(app, ~, ~)
            port = app.ServerPortEdit.Value;
            try
                % 初始化在线客户端字典
                app.ConnectedClients = containers.Map('KeyType', 'char', 'ValueType', 'any');
                
                % 使用 udp datagram 模式，突破 tcpserver 单人限制
                app.Server = udpport("datagram", "IPV4", "LocalPort", port);
                configureCallback(app.Server, "datagram", 1, @app.receiveMessageServer);
                
                app.ConnectionMode = 'server';
                app.updateUIState('server_listening');
                app.appendChatMsg('系统', sprintf('主机已启动！监听端口 %d (支持无限多人同时连入)...', port));
            catch ME
                uialert(app.UIFigure,['主机启动失败: ', ME.message], '错误');
                app.stopServer();
            end
        end
        
        function stopServer(app, ~, ~)
            if ~isempty(app.Server)
                % 提前广播解散通知
                if app.ConnectedClients.Count > 0
                    try app.sendToNetwork('SYS', '系统', '主机已关闭聊天室。'); catch; end
                end
                delete(app.Server); 
                app.Server =[]; 
            end
            
            app.ConnectionMode = 'none';
            app.updateUIState('disconnected');
            app.appendChatMsg('系统', '主机已停止。');
        end
        
        function receiveMessageServer(app, src, ~)
            % 循环读取所有积压的 UDP 数据报
            while src.NumDatagramsAvailable > 0
                dg = read(src, 1, "uint8"); % 读取单个数据报
                rawData = dg.Data;
                senderIP = string(dg.SenderAddress);
                senderPort = double(dg.SenderPort);
                
                % 生成唯一 Key: "IP_Port"
                clientKey = sprintf('%s_%d', senderIP, senderPort);
                
                % 如果是新客机，加入到广播列表并更新 UI
                if ~isKey(app.ConnectedClients, clientKey)
                    app.ConnectedClients(clientKey) = struct('IP', senderIP, 'Port', senderPort);
                    app.ServerStatusLabel.Text = sprintf('状态: 监听中 (累计连入 %d 人)', app.ConnectedClients.Count);
                    drawnow;
                end
                
                dataStr = string(char(rawData));
                
                % 1. 原封不动将密文【广播给所有已知的客机】
                allKeys = keys(app.ConnectedClients);
                for i = 1:length(allKeys)
                    c = app.ConnectedClients(allKeys{i});
                    try write(app.Server, rawData, "uint8", c.IP, c.Port); catch; end
                end
                
                % 2. 主机本地解密显示
                app.processIncomingData(dataStr);
            end
        end
        
        %% 客机逻辑
        function connectToServer(app, ~, ~)
            ip = app.ClientIPEdit.Value;
            port = app.ClientPortEdit.Value;
            try
                app.updateUIState('client_connecting');
                
                % 客机绑定随机可用本地端口即可
                app.Client = udpport("datagram", "IPV4");
                configureCallback(app.Client, "datagram", 1, @app.receiveMessageClient);
                
                % 记录主机的目标地址，用于发送消息
                app.HostIP = ip;
                app.HostPort = port;
                
                app.ConnectionMode = 'client';
                app.updateUIState('client_connected');
                app.appendChatMsg('系统', sprintf('成功进入房间 %s:%d', ip, port));
                
                % 发送加入广播（主机会借此抓取并记录客机的IP和随机Port）
                username = app.UserNameEdit.Value;
                if isempty(username), username = '匿名'; end
                joinMsg = sprintf('用户[%s] 加入了多人聊天室！', username);
                app.sendToNetwork('SYS', '系统', joinMsg);
                
            catch ME
                uialert(app.UIFigure,['连接失败: ', ME.message], '网络错误');
                app.disconnectFromServer();
            end
        end
        
        function disconnectFromServer(app, ~, ~)
            if ~isempty(app.Client)
                try
                    username = app.UserNameEdit.Value;
                    if isempty(username), username = '匿名'; end
                    leaveMsg = sprintf('用户 [%s] 离开了房间。', username);
                    app.sendToNetwork('SYS', '系统', leaveMsg);
                catch
                end
                delete(app.Client);
                app.Client =[];
            end
            app.ConnectionMode = 'none';
            app.updateUIState('disconnected');
            app.appendChatMsg('系统', '已断开与主机的连接。');
        end
        
        function receiveMessageClient(app, src, ~)
            % 客户端接收主机的广播回传
            while src.NumDatagramsAvailable > 0
                dg = read(src, 1, "uint8");
                dataStr = string(char(dg.Data));
                app.processIncomingData(dataStr);
            end
        end
        
        %% 数据包封装与解析引擎 (★核心中文防丢包机制★)
        function sendToNetwork(app, senderID, senderName, msgContent)
            % 将 中文转换成 UTF8 字节，再转化为纯 ASCII 的 Base64 编码
            nameB64 = matlab.net.base64encode(unicode2native(char(senderName), 'UTF-8'));
            msgB64  = matlab.net.base64encode(unicode2native(char(msgContent), 'UTF-8'));
            
            % 封包格式: UUID | Name(Base64) | Msg(Base64)
            wireStr = sprintf('%s|%s|%s', senderID, nameB64, msgB64);
            rawData = uint8(char(wireStr));
            
            % 根据当前模式定向发送数据
            if strcmp(app.ConnectionMode, 'server')
                % 主机发消息：遍历列表，直接群发给所有人
                allKeys = keys(app.ConnectedClients);
                for i = 1:length(allKeys)
                    c = app.ConnectedClients(allKeys{i});
                    try write(app.Server, rawData, "uint8", c.IP, c.Port); catch; end
                end
            elseif strcmp(app.ConnectionMode, 'client')
                % 客机发消息：只发给主机（由主机代为中转广播）
                try write(app.Client, rawData, "uint8", app.HostIP, app.HostPort); catch; end
            end
        end
        
        function processIncomingData(app, wireData)
            wireData = string(wireData);
            parts = split(wireData, '|');
            
            if numel(parts) >= 3
                senderID = char(parts(1));
                
                % 解码 Base64 还原中文
                try
                    senderName = string(native2unicode(matlab.net.base64decode(char(parts(2))), 'UTF-8'));
                    msg = string(native2unicode(matlab.net.base64decode(char(parts(3))), 'UTF-8'));
                catch
                    senderName = "系统解码";
                    msg = "[收到一条无法解析的消息]";
                end
                
                % 忽略自己发出后被主机广播回来的包
                if strcmp(senderID, app.MyClientID)
                    return;
                end
                
                if strcmp(senderID, 'SYS')
                    app.appendChatMsg('系统', msg);
                else
                    app.appendChatMsg(senderName, msg);
                end
            end
        end
        
        %% 消息发送逻辑
        function sendMessage(app, ~, ~)
            rawMsg = app.MessageInputField.Value;
            if isempty(rawMsg), return; end
            msgStr = strjoin(rawMsg, ' '); 
            if strlength(strtrim(msgStr)) == 0, return; end
            
            username = app.UserNameEdit.Value;
            if isempty(username), username = '匿名'; end
            
            try
                app.sendToNetwork(app.MyClientID, username, msgStr);
                app.appendChatMsg('我', msgStr); 
                app.MessageInputField.Value = ''; 
            catch
                uialert(app.UIFigure, '发送失败，请检查网络。', '网络错误');
            end
        end
        
        %% 辅助显示方法
        function appendChatMsg(app, sender, msg)
            timestamp = char(datetime('now', 'Format', 'HH:mm:ss'));
            username = app.UserNameEdit.Value;
            if isempty(username), username = '匿名'; end
            
            if strcmp(sender, '我')
                newMsg = sprintf('[%s] 我(%s): %s', timestamp, username, msg);
            else
                newMsg = sprintf('[%s] %s: %s', timestamp, sender, msg);
            end
            
            currentText = app.ChatHistoryArea.Value;
            if isempty(currentText)
                app.ChatHistoryArea.Value = {newMsg};
            else
                if ischar(currentText), currentText = {currentText}; end
                app.ChatHistoryArea.Value =[currentText; {newMsg}];
            end
            scroll(app.ChatHistoryArea, 'bottom');
        end
        
        function updateUIState(app, state)
            switch state
                case 'disconnected'
                    app.ServerPortEdit.Enable = 'on';
                    app.ServerStartBtn.Enable = 'on';
                    app.ServerStopBtn.Enable = 'off';
                    app.ServerStatusLabel.Text = '状态: 未启动';
                    app.ServerStatusLabel.FontColor =[0.6 0 0];
                    
                    app.ClientIPEdit.Enable = 'on';
                    app.ClientPortEdit.Enable = 'on';
                    app.ClientConnectBtn.Enable = 'on';
                    app.ClientDisconnBtn.Enable = 'off';
                    app.ClientStatusLabel.Text = '状态: 未连接';
                    app.ClientStatusLabel.FontColor =[0.6 0 0];
                    
                    app.ClientPanel.Enable = 'on';
                    app.ServerPanel.Enable = 'on';
                    app.SendBtn.Enable = 'off';
                    
                case 'server_listening'
                    app.ServerPortEdit.Enable = 'off';
                    app.ServerStartBtn.Enable = 'off';
                    app.ServerStopBtn.Enable = 'on';
                    
                    app.ServerStatusLabel.Text = '状态: 监听中 (累计连入 0 人)';
                    app.ServerStatusLabel.FontColor =[0 0.6 0];
                    
                    app.ClientPanel.Enable = 'off';
                    app.SendBtn.Enable = 'on'; 
                    
                case 'client_connecting'
                    app.ClientConnectBtn.Enable = 'off';
                    app.ClientStatusLabel.Text = '状态: 连接中...';
                    app.ClientStatusLabel.FontColor =[0.8 0.6 0];
                    
                case 'client_connected'
                    app.ClientIPEdit.Enable = 'off';
                    app.ClientPortEdit.Enable = 'off';
                    app.ClientConnectBtn.Enable = 'off';
                    app.ClientDisconnBtn.Enable = 'on';
                    app.ClientStatusLabel.Text = '状态: 已连接';
                    app.ClientStatusLabel.FontColor =[0 0.6 0];
                    
                    app.ServerPanel.Enable = 'off';
                    app.SendBtn.Enable = 'on';
            end
        end
        
        function onKeyPress(app, ~, event)
            if strcmp(event.Key, 'return') && strcmp(event.Modifier, 'control')
                app.sendMessage();
            end
        end
    end
    
    % =====================================================================
    % 界面初始化区域
    % =====================================================================
    methods (Access = private)
        function createComponents(app)
            app.UIFigure = uifigure('Position',[100 100 850 640]);
            app.UIFigure.Name = '局域网多人聊天室 - 强制防乱码UDP群组版';
            app.UIFigure.Color = '#F0F0F0';
            app.UIFigure.WindowKeyPressFcn = @app.onKeyPress;
            
            % 为每个设备生成独一无二的 UUID (用于忽略接收自己的广播包)
            app.MyClientID = char(java.util.UUID.randomUUID().toString());
            
            app.MainGrid = uigridlayout(app.UIFigure);
            app.MainGrid.ColumnWidth = {'1x'};
            app.MainGrid.RowHeight = {40, 150, '1x', 100};
            
            app.UserGrid = uigridlayout(app.MainGrid);
            app.UserGrid.Layout.Row = 1;
            app.UserGrid.Layout.Column = 1;
            app.UserGrid.ColumnWidth = {80, 150, '1x'};
            app.UserGrid.RowHeight = {'1x'};
            app.UserGrid.Padding = [10 0 10 0];
            
            uilabel(app.UserGrid, 'Text', '我的昵称:', 'FontWeight', 'bold', 'HorizontalAlignment', 'right');
            app.UserNameEdit = uieditfield(app.UserGrid, 'text');
            app.UserNameEdit.Value = sprintf('User%d', randi([1000, 9999]));
            
            app.TopGrid = uigridlayout(app.MainGrid);
            app.TopGrid.Layout.Row = 2;
            app.TopGrid.Layout.Column = 1;
            app.TopGrid.ColumnWidth = {'1x', '1x'};
            app.TopGrid.RowHeight = {'1x'};
            app.TopGrid.Padding =[0 0 0 0];
            
            %% 4.1 左侧：服务端面板
            app.ServerPanel = uipanel(app.TopGrid);
            app.ServerPanel.Title = '主机设置 (支持多人连入与路由)';
            app.ServerPanel.Layout.Row = 1;
            app.ServerPanel.Layout.Column = 1;
            
            uilabel(app.ServerPanel, 'Position',[20 85 80 22], 'Text', '监听端口:');
            app.ServerPortEdit = uieditfield(app.ServerPanel, 'numeric', 'Position',[100 85 100 22]);
            app.ServerPortEdit.Value = 8888;
            
            uilabel(app.ServerPanel, 'Position',[20 62 250 22], 'Text', '注: 只需要1个端口，支持无限台客机同时连入', 'FontSize', 11, 'FontColor',[0.4 0.4 0.4]);
            
            app.ServerStartBtn = uibutton(app.ServerPanel, 'push', 'Position',[20 30 80 30], 'Text', '启动主机');
            app.ServerStartBtn.ButtonPushedFcn = @app.startServer;
            
            app.ServerStopBtn = uibutton(app.ServerPanel, 'push', 'Position',[120 30 80 30], 'Text', '停止主机', 'Enable', 'off');
            app.ServerStopBtn.ButtonPushedFcn = @app.stopServer;
            
            app.ServerStatusLabel = uilabel(app.ServerPanel, 'Position',[20 5 250 22], 'Text', '状态: 未启动', 'FontWeight', 'bold', 'FontColor',[0.6 0 0]);
            
            %% 4.2 右侧：客户端面板
            app.ClientPanel = uipanel(app.TopGrid);
            app.ClientPanel.Title = '客机设置 (连接到主机房间)';
            app.ClientPanel.Layout.Row = 1;
            app.ClientPanel.Layout.Column = 2;
            
            uilabel(app.ClientPanel, 'Position',[20 95 80 22], 'Text', '主机 IP:');
            app.ClientIPEdit = uieditfield(app.ClientPanel, 'text', 'Position',[100 95 150 22]);
            app.ClientIPEdit.Value = '127.0.0.1';
            
            uilabel(app.ClientPanel, 'Position',[20 65 80 22], 'Text', '目标端口:');
            app.ClientPortEdit = uieditfield(app.ClientPanel, 'numeric', 'Position',[100 65 100 22]);
            app.ClientPortEdit.Value = 8888;
            
            app.ClientConnectBtn = uibutton(app.ClientPanel, 'push', 'Position',[20 25 80 30], 'Text', '连入房间');
            app.ClientConnectBtn.ButtonPushedFcn = @app.connectToServer;
            
            app.ClientDisconnBtn = uibutton(app.ClientPanel, 'push', 'Position',[120 25 80 30], 'Text', '断开', 'Enable', 'off');
            app.ClientDisconnBtn.ButtonPushedFcn = @app.disconnectFromServer;
            
            app.ClientStatusLabel = uilabel(app.ClientPanel, 'Position',[20 5 250 22], 'Text', '状态: 未连接', 'FontWeight', 'bold', 'FontColor',[0.6 0 0]);
            
            %% 5. 中部：聊天记录区
            app.ChatHistoryArea = uitextarea(app.MainGrid);
            app.ChatHistoryArea.Layout.Row = 3;
            app.ChatHistoryArea.Layout.Column = 1;
            app.ChatHistoryArea.Editable = 'off';
            app.ChatHistoryArea.FontSize = 14; 
            app.ChatHistoryArea.Value = {'=== 欢迎使用 MATLAB 多人局域网聊天 App ===', ...
                                         '【支持完美识别、收发中英文字符、无限人连入】', ...
                                         '1. 主机模式：一人担任主机开启端口(如8888)，即可作为群聊服务器。', ...
                                         '2. 客机模式：多人分别输入主机IP与端口并连入，人数不限。', ...
                                         '提示：按 Ctrl+Enter 快捷发送消息'};
            
            %% 6. 底部：消息输入区
            app.BottomGrid = uigridlayout(app.MainGrid);
            app.BottomGrid.Layout.Row = 4;
            app.BottomGrid.Layout.Column = 1;
            app.BottomGrid.ColumnWidth = {'1x', 120};
            app.BottomGrid.RowHeight = {'1x'};
            app.BottomGrid.Padding =[0 0 0 0];
            
            app.MessageInputField = uitextarea(app.BottomGrid);
            app.MessageInputField.Layout.Row = 1;
            app.MessageInputField.Layout.Column = 1;
            app.MessageInputField.FontSize = 14;
            
            app.SendBtn = uibutton(app.BottomGrid, 'push');
            app.SendBtn.Layout.Row = 1;
            app.SendBtn.Layout.Column = 2;
            app.SendBtn.Text = '发 送';
            app.SendBtn.FontSize = 16;
            app.SendBtn.FontWeight = 'bold';
            app.SendBtn.Enable = 'off';
            app.SendBtn.ButtonPushedFcn = @app.sendMessage;
            
            app.ConnectionMode = 'none';
        end
    end
    
    methods (Access = public)
        function app = LanChatApp1
            createComponents(app);
            movegui(app.UIFigure, 'center');
            registerApp(app, app.UIFigure);
        end
        
        function delete(app)
            try
                if ~isempty(app.Server), delete(app.Server); end
                if ~isempty(app.Client), delete(app.Client); end
            catch
            end
            delete(app.UIFigure);
        end
    end
end