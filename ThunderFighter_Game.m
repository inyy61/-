function ThunderFighter_Game()
    % =====================================================================
    % 游戏初始化与全局状态设置
    % =====================================================================
    isGameRunning = true;
    gameState = 'PLAYING'; % 'PLAYING' 或 'GAMEOVER'
    score = 0;
    level = 1;
    
    % 物理与游戏参数
    FPS = 60;
    dt = 1 / FPS;
    gameArea =[0, 100, 0, 100]; %[Xmin, Xmax, Ymin, Ymax]
    
    % 玩家状态
    player = struct('x', 50, 'y', 8, 'w', 7, 'h', 8, 'handle',[]);
    isShooting = false;
    pShootCooldown = 0;
    pShootDelay = 8; % 射击间隔(帧)
    
    % 定义玩家战机多边形 (现代战斗机造型)
    playerShapeX =[0,  0.5,  3.5,  1.0,  1.2,   0, -1.2, -1.0, -3.5, -0.5];
    playerShapeY =[4,  1.0, -1.5, -1.5, -3.5, -2.5, -3.5, -1.5, -1.5,  1.0];

    % 定义敌人战机多边形 (异形侵入者造型，机头朝下)
    enemyShapeX =[0,  1.0,  3.0,  1.5,  0.5,   0, -0.5, -1.5, -3.0, -1.0];
    enemyShapeY =[-3, -1.0,  1.5,  1.5,  3.0, 2.0,  3.0,  1.5,  1.5, -1.0];
    
    % 实体列表
    pBullets =[]; 
    eBullets = []; 
    enemies =[];  
    particles =[];
    
    % UI句柄
    scoreText =[];
    
    % 敌人运动控制
    enemyDir = 1; 
    enemySpeedX = 0;
    
    % =====================================================================
    % 创建图形窗口与界面
    % =====================================================================
    fig = figure('Name', '雷霆战机 - 进化版', ...
        'NumberTitle', 'off', ...
        'MenuBar', 'none', ...
        'ToolBar', 'none', ...
        'Color',[0.05 0.05 0.1], ... % 暗夜空背景
        'Position',[300, 100, 600, 800], ...
        'KeyPressFcn', @onKeyPress, ...
        'WindowButtonMotionFcn', @onMouseMove, ...
        'WindowButtonDownFcn', @onMouseDown, ...
        'WindowButtonUpFcn', @onMouseUp, ...
        'CloseRequestFcn', @onClose);
    
    ax = axes('Parent', fig, ...
        'Position', [0 0 1 1], ...
        'XLim',[gameArea(1) gameArea(2)], ...
        'YLim', [gameArea(3) gameArea(4)], ...
        'Color', 'none', ...
        'XColor', 'none', ...
        'YColor', 'none');
    hold(ax, 'on');
    
    % 初始化图形元素
    initGraphics();
    startNewLevel();
    
    % =====================================================================
    % 主游戏循环
    % =====================================================================
    while isGameRunning && ishandle(fig)
        tic; % 记录帧开始时间
        
        if strcmp(gameState, 'PLAYING')
            updatePlayerAction();
            updateBullets();
            updateEnemies();
            updateParticles();
            checkCollisions();
            checkLevelProgress();
        elseif strcmp(gameState, 'GAMEOVER')
            updateParticles();
        end
        
        % 刷新画面 (增加 ishandle 判断防止窗口已关时报错)
        if ishandle(fig)
            drawnow limitrate;
        end
        
        % 控制帧率 (~60 FPS)
        elapsedTime = toc;
        if elapsedTime < dt
            pause(dt - elapsedTime);
        end
    end
    
    % 确保跳出循环后窗口被正确销毁
    if ishandle(fig)
        delete(fig);
    end
    
    % =====================================================================
    % 游戏逻辑更新函数
    % =====================================================================
    
    function updatePlayerAction()
        if pShootCooldown > 0
            pShootCooldown = pShootCooldown - 1;
        end
        if isShooting && pShootCooldown <= 0
            spawnPlayerBullet(player.x, player.y + player.h/2);
            pShootCooldown = pShootDelay;
        end
    end

    function updateBullets()
        % 玩家子弹
        pBulletSpeed = 2.0;
        killIdx =[];
        for i = 1:length(pBullets)
            pBullets(i).y = pBullets(i).y + pBulletSpeed;
            set(pBullets(i).handle, 'YData',[pBullets(i).y, pBullets(i).y - 4]); 
            if pBullets(i).y > gameArea(4)
                killIdx = [killIdx, i];
            end
        end
        removePlayerBullets(killIdx);
        
        % 敌方子弹
        eBulletSpeed = 0.8 + 0.1 * level;
        killIdx =[];
        for i = 1:length(eBullets)
            eBullets(i).y = eBullets(i).y - eBulletSpeed;
            set(eBullets(i).handle, 'YData',[eBullets(i).y, eBullets(i).y + 2]);
            if eBullets(i).y < gameArea(3)
                killIdx = [killIdx, i];
            end
        end
        removeEnemyBullets(killIdx);
    end

    function updateEnemies()
        moveDown = false;
        leftMost = 100; rightMost = 0;
        
        for i = 1:length(enemies)
            if enemies(i).alive
                leftMost = min(leftMost, enemies(i).x);
                rightMost = max(rightMost, enemies(i).x);
            end
        end
        
        if rightMost > gameArea(2) - 4
            enemyDir = -1;
            moveDown = true;
        elseif leftMost < gameArea(1) + 4
            enemyDir = 1;
            moveDown = true;
        end
        
        fireChance = 0.005 + 0.002 * level; 
        
        for i = 1:length(enemies)
            if enemies(i).alive
                enemies(i).x = enemies(i).x + enemyDir * enemySpeedX;
                if moveDown
                    enemies(i).y = enemies(i).y - 4;
                end
                
                % 更新酷炫的敌方战机位置
                set(enemies(i).handle, 'XData', enemyShapeX + enemies(i).x, 'YData', enemyShapeY + enemies(i).y);
                
                if rand() < fireChance
                    spawnEnemyBullet(enemies(i).x, enemies(i).y - 3);
                end
            end
        end
    end

    function updateParticles()
        killIdx =[];
        for i = 1:length(particles)
            particles(i).x = particles(i).x + particles(i).vx;
            particles(i).y = particles(i).y + particles(i).vy;
            particles(i).life = particles(i).life - 1;
            
            if particles(i).life <= 0
                delete(particles(i).handle);
                killIdx = [killIdx, i];
            else
                set(particles(i).handle, 'XData', particles(i).x, 'YData', particles(i).y);
                if mod(particles(i).life, 5) == 0
                    ms = get(particles(i).handle, 'MarkerSize');
                    set(particles(i).handle, 'MarkerSize', max(1, ms-1));
                end
            end
        end
        particles(killIdx) =[];
    end

    function checkCollisions()
        % 1. 玩家击中敌机 (优化碰撞箱)
        killPB =[];
        for i = 1:length(pBullets)
            hit = false;
            for j = 1:length(enemies)
                if enemies(j).alive
                    if abs(pBullets(i).x - enemies(j).x) < 3.5 && abs(pBullets(i).y - enemies(j).y) < 3
                        enemies(j).alive = false;
                        set(enemies(j).handle, 'Visible', 'off');
                        spawnExplosion(enemies(j).x, enemies(j).y,[1 0.6 0]); 
                        hit = true;
                        score = score + 10;
                        updateScoreText();
                        break;
                    end
                end
            end
            if hit
                killPB = [killPB, i];
            end
        end
        removePlayerBullets(killPB);
        
        % 2. 敌方子弹击中玩家
        for i = 1:length(eBullets)
            if abs(eBullets(i).x - player.x) < 3.5 && abs(eBullets(i).y - player.y) < 4
                triggerGameOver();
                return;
            end
        end
        
        % 3. 敌机撞击玩家
        for i = 1:length(enemies)
            if enemies(i).alive
                if (abs(enemies(i).x - player.x) < 6 && abs(enemies(i).y - player.y) < 6) || enemies(i).y < player.y - 2
                    triggerGameOver();
                    return;
                end
            end
        end
    end

    function checkLevelProgress()
        aliveCount = sum([enemies.alive]);
        if aliveCount == 0
            level = level + 1;
            startNewLevel();
        end
    end

    % =====================================================================
    % 辅助生成与清理函数
    % =====================================================================
    
    function startNewLevel()
        removePlayerBullets(1:length(pBullets));
        removeEnemyBullets(1:length(eBullets));
        
        for i = 1:length(enemies)
            if ishandle(enemies(i).handle), delete(enemies(i).handle); end
        end
        enemies =[];
        
        rows = min(3 + floor(level/2), 6); 
        cols = min(5 + floor(level/3), 9); 
        enemySpeedX = min(0.3 + 0.08 * level, 1.2);
        
        startX = 50 - (cols-1)*5;
        startY = 90;
        
        colors = lines(rows); 
        
        for r = 1:rows
            for c = 1:cols
                ex = startX + (c-1)*10;
                ey = startY - (r-1)*8;
                
                % 绘制酷炫敌机
                h = patch(ax, enemyShapeX + ex, enemyShapeY + ey, colors(r,:), ...
                    'EdgeColor', 'w', 'LineWidth', 0.8, 'FaceAlpha', 0.85);
                
                enemyStruct = struct('x', ex, 'y', ey, 'alive', true, 'handle', h);
                enemies = [enemies, enemyStruct];
            end
        end
        
        lvlText = text(ax, 50, 50, sprintf('WAVE %d', level), ...
            'Color', 'w', 'FontSize', 24, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
        drawnow; pause(1);
        if ishandle(lvlText), delete(lvlText); end
    end

    function spawnPlayerBullet(x, y)
        h = line(ax, [x, x], [y, y-4], 'Color',[0 1 1], 'LineWidth', 2.5);
        pBullets =[pBullets, struct('x', x, 'y', y, 'handle', h)];
    end

    function spawnEnemyBullet(x, y)
        h = line(ax, [x, x],[y, y+2], 'Color', [1 0.2 0.2], 'LineWidth', 2);
        eBullets =[eBullets, struct('x', x, 'y', y, 'handle', h)];
    end

    function spawnExplosion(x, y, color)
        numParticles = 8;
        for i = 1:numParticles
            ang = rand() * 2 * pi;
            spd = rand() * 1.5 + 0.5;
            vx = cos(ang) * spd;
            vy = sin(ang) * spd;
            h = line(ax, x, y, 'Marker', '.', 'Color', color, 'MarkerSize', 10 + rand()*5, 'LineStyle', 'none');
            particles =[particles, struct('x', x, 'y', y, 'vx', vx, 'vy', vy, 'life', 15 + randi(10), 'handle', h)];
        end
    end

    function removePlayerBullets(indices)
        if isempty(indices), return; end
        for i = indices
            if ishandle(pBullets(i).handle), delete(pBullets(i).handle); end
        end
        pBullets(indices) =[];
    end

    function removeEnemyBullets(indices)
        if isempty(indices), return; end
        for i = indices
            if ishandle(eBullets(i).handle), delete(eBullets(i).handle); end
        end
        eBullets(indices) =[];
    end

    function triggerGameOver()
        gameState = 'GAMEOVER';
        spawnExplosion(player.x, player.y, [0 1 1]); 
        set(player.handle, 'Visible', 'off');
        text(ax, 50, 55, 'GAME OVER', ...
            'Color', 'r', 'FontSize', 40, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
        text(ax, 50, 45, sprintf('FINAL SCORE: %d', score), ...
            'Color', 'w', 'FontSize', 20, 'HorizontalAlignment', 'center');
        text(ax, 50, 35, 'Press ESC to exit', ...
            'Color',[0.7 0.7 0.7], 'FontSize', 12, 'HorizontalAlignment', 'center');
    end

    function initGraphics()
        % 绘制玩家高科技战机
        player.handle = patch(ax, playerShapeX + player.x, playerShapeY + player.y, [0 0.8 1], ...
            'EdgeColor', [0 1 1], 'LineWidth', 1.5, 'FaceAlpha', 0.8);
        
        % 得分UI
        scoreText = text(ax, 2, 96, 'SCORE: 0', ...
            'Color', 'w', 'FontSize', 14, 'FontWeight', 'bold', 'FontName', 'Courier');
        
        % 星星背景装饰
        starX = rand(1, 50) * 100;
        starY = rand(1, 50) * 100;
        scatter(ax, starX, starY, 2,[0.8 0.8 1], 'filled', 'MarkerFaceAlpha', 0.5);
    end

    function updateScoreText()
        if ishandle(scoreText)
            set(scoreText, 'String', sprintf('SCORE: %d', score));
        end
    end

    % =====================================================================
    % 回调事件响应 (防止句柄被销毁后报错)
    % =====================================================================
    
    function onMouseMove(~, ~)
        if ~isGameRunning || ~ishandle(ax), return; end
        if ~strcmp(gameState, 'PLAYING') || ~ishandle(player.handle), return; end
        
        cp = ax.CurrentPoint;
        newX = cp(1, 1);
        player.x = max(player.w/2, min(gameArea(2) - player.w/2, newX));
        
        set(player.handle, 'XData', playerShapeX + player.x);
    end

    function onMouseDown(~, ~)
        if strcmp(gameState, 'PLAYING')
            isShooting = true;
        end
    end

    function onMouseUp(~, ~)
        isShooting = false;
    end

    function onKeyPress(~, event)
        if strcmp(event.Key, 'escape')
            isGameRunning = false;
            % 解决 ESC 按下无响应：直接销毁窗口强制结束游戏
            if ishandle(fig)
                delete(fig);
            end
        end
    end

    function onClose(~, ~)
        isGameRunning = false;
        if ishandle(fig)
            delete(fig);
        end
    end

end