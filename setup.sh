#!/bin/bash

# Create all project files

cat > main.py << 'EOF'
import streamlit as st
import pandas as pd
from data_fetcher import CoinbaseDataFetcher
from pattern_detection import PatternDetector
from charting import create_candlestick_chart
from risk_calculator import RiskCalculator
from alerts import AlertManager
from trade_journal import TradeJournal
import os
from dotenv import load_dotenv

load_dotenv()

st.set_page_config(
    page_title="Crypto Pattern Dashboard",
    page_icon="📊",
    layout="wide",
    initial_sidebar_state="expanded"
)

st.sidebar.title("⚙️ Dashboard Settings")
symbol = st.sidebar.selectbox(
    "Select Crypto Pair",
    ["BTC-USD", "ETH-USD", "SOL-USD", "XRP-USD", "ADA-USD", "AVAX-USD"]
)

timeframe = st.sidebar.selectbox(
    "Timeframe",
    ["15m", "1h", "4h", "1d"]
)

risk_percentage = st.sidebar.slider(
    "Risk % per trade",
    0.1, 5.0, 1.0, 0.1
)

fetcher = CoinbaseDataFetcher(
    api_key=os.getenv("COINBASE_API_KEY"),
    api_secret=os.getenv("COINBASE_API_SECRET"),
    passphrase=os.getenv("COINBASE_PASSPHRASE")
)

detector = PatternDetector()
calculator = RiskCalculator()
alerts = AlertManager()
journal = TradeJournal()

st.title("📊 Crypto Pattern Analysis Dashboard")
st.markdown("---")

@st.cache_data(ttl=300)
def get_market_data():
    return fetcher.fetch_ohlc(symbol, timeframe)

try:
    df = get_market_data()
    
    if df is not None and len(df) > 0:
        df = detector.analyze_structure(df)
        
        col1, col2 = st.columns([3, 1])
        
        with col1:
            st.subheader(f"{symbol} - {timeframe} Chart")
            fig = create_candlestick_chart(df, symbol)
            st.plotly_chart(fig, use_container_width=True)
        
        with col2:
            st.subheader("📈 Market Structure")
            latest = df.iloc[-1]
            
            structure = "🟢 BULLISH" if latest.get('structure') == 'bullish' else "🔴 BEARISH"
            st.write(f"**Structure:** {structure}")
            
            if latest.get('bos'):
                st.write("🔥 **Break of Structure!**")
            
            if latest.get('pattern'):
                st.write(f"**Pattern:** {latest['pattern']}")
        
        tab1, tab2, tab3, tab4 = st.tabs(["Patterns", "Risk Setup", "Alerts", "Journal"])
        
        with tab1:
            st.subheader("🎯 Detected Patterns")
            patterns_df = df[df['pattern'].notna()][['time', 'close', 'pattern']].tail(10)
            if len(patterns_df) > 0:
                st.dataframe(patterns_df, use_container_width=True)
            else:
                st.info("No patterns detected in current view")
        
        with tab2:
            st.subheader("💰 Risk/Reward Calculator")
            
            entry_price = st.number_input("Entry Price", value=float(df.iloc[-1]['close']))
            stop_loss = st.number_input("Stop Loss Price")
            
            if entry_price > 0 and stop_loss > 0:
                account_size = st.number_input("Account Size ($)", value=10000)
                
                setup = calculator.calculate_setup(
                    entry_price,
                    stop_loss,
                    account_size,
                    risk_percentage
                )
                
                col1, col2, col3, col4 = st.columns(4)
                col1.metric("Position Size", f"{setup['position_size']:.4f}")
                col2.metric("Risk Amount", f"${setup['risk_amount']:.2f}")
                col3.metric("1:2 TP", f"{setup['tp_1_2']:.2f}")
                col4.metric("1:3 TP", f"{setup['tp_1_3']:.2f}")
        
        with tab3:
            st.subheader("🔔 Alert Configuration")
            
            alert_type = st.selectbox("Alert Type", ["Email", "Discord", "Slack"])
            alert_threshold = st.slider("Alert Sensitivity", 0.1, 1.0, 0.5)
            
            if st.button("Enable Alerts"):
                st.success(f"✅ {alert_type} alerts enabled!")
        
        with tab4:
            st.subheader("📝 Trade Journal")
            
            col1, col2, col3 = st.columns(3)
            with col1:
                entry = st.number_input("Entry Price (Journal)")
            with col2:
                exit_price = st.number_input("Exit Price")
            with col3:
                pnl = st.number_input("P&L")
            
            if st.button("Log Trade"):
                trade = {
                    'symbol': symbol,
                    'entry': entry,
                    'exit': exit_price,
                    'pnl': pnl,
                    'timestamp': pd.Timestamp.now()
                }
                journal.add_trade(trade)
                st.success("✅ Trade logged!")
            
            st.subheader("Recent Trades")
            trades = journal.get_recent_trades(10)
            if len(trades) > 0:
                st.dataframe(trades, use_container_width=True)
    
    else:
        st.error("❌ Failed to fetch data")

except Exception as e:
    st.error(f"❌ Error: {str(e)}")
    st.info("Make sure your API credentials are set in .env file")
EOF

cat > data_fetcher.py << 'EOF'
import requests
import pandas as pd
import ccxt
from datetime import datetime, timedelta

class CoinbaseDataFetcher:
    def __init__(self, api_key, api_secret, passphrase):
        self.exchange = ccxt.coinbase({
            'apiKey': api_key,
            'secret': api_secret,
            'password': passphrase
        })
    
    def fetch_ohlc(self, symbol, timeframe='1h', limit=100):
        try:
            timeframe_map = {
                '15m': '15m',
                '1h': '1h',
                '4h': '4h',
                '1d': '1d'
            }
            
            tf = timeframe_map.get(timeframe, '1h')
            
            ohlcv = self.exchange.fetch_ohlcv(symbol, tf, limit=limit)
            
            df = pd.DataFrame(
                ohlcv,
                columns=['timestamp', 'open', 'high', 'low', 'close', 'volume']
            )
            
            df['time'] = pd.to_datetime(df['timestamp'], unit='ms')
            df = df.drop('timestamp', axis=1)
            df = df.sort_values('time').reset_index(drop=True)
            
            return df
        
        except Exception as e:
            print(f"Error fetching data: {e}")
            return None
EOF

cat > pattern_detection.py << 'EOF'
import pandas as pd
import numpy as np

class PatternDetector:
    def __init__(self, lookback=50):
        self.lookback = lookback
    
    def analyze_structure(self, df):
        df['higher_high'] = False
        df['higher_low'] = False
        df['lower_high'] = False
        df['lower_low'] = False
        df['structure'] = None
        df['bos'] = False
        df['pattern'] = None
        
        for i in range(2, len(df)):
            prev_high = df.iloc[i-2:i]['high'].max()
            prev_low = df.iloc[i-2:i]['low'].min()
            curr_high = df.iloc[i]['high']
            curr_low = df.iloc[i]['low']
            
            if curr_high > prev_high:
                df.loc[i, 'higher_high'] = True
            if curr_low > prev_low:
                df.loc[i, 'higher_low'] = True
            if curr_high < prev_high:
                df.loc[i, 'lower_high'] = True
            if curr_low < prev_low:
                df.loc[i, 'lower_low'] = True
            
            hh_count = df.iloc[max(0, i-5):i]['higher_high'].sum()
            hl_count = df.iloc[max(0, i-5):i]['higher_low'].sum()
            lh_count = df.iloc[max(0, i-5):i]['lower_high'].sum()
            ll_count = df.iloc[max(0, i-5):i]['lower_low'].sum()
            
            if hh_count >= 2 or hl_count >= 2:
                df.loc[i, 'structure'] = 'bullish'
            elif lh_count >= 2 or ll_count >= 2:
                df.loc[i, 'structure'] = 'bearish'
        
        df = self._detect_bos(df)
        df = self._detect_patterns(df)
        
        return df
    
    def _detect_bos(self, df):
        for i in range(10, len(df)):
            window = df.iloc[i-10:i]
            
            if df.loc[i-1, 'structure'] == 'bullish' and df.loc[i, 'low'] < window['low'].min():
                df.loc[i, 'bos'] = True
                df.loc[i, 'pattern'] = 'Bearish BOS'
            
            if df.loc[i-1, 'structure'] == 'bearish' and df.loc[i, 'high'] > window['high'].max():
                df.loc[i, 'bos'] = True
                df.loc[i, 'pattern'] = 'Bullish BOS'
        
        return df
    
    def _detect_patterns(self, df):
        for i in range(1, len(df)):
            if (df.iloc[i-1]['close'] > df.iloc[i-1]['open'] and
                df.iloc[i]['close'] < df.iloc[i]['open'] and
                df.iloc[i]['close'] < df.iloc[i-1]['open']):
                df.loc[i, 'pattern'] = 'Bearish Engulfing'
            
            if (df.iloc[i-1]['close'] < df.iloc[i-1]['open'] and
                df.iloc[i]['close'] > df.iloc[i]['open'] and
                df.iloc[i]['close'] > df.iloc[i-1]['open']):
                df.loc[i, 'pattern'] = 'Bullish Engulfing'
            
            if i > 5:
                prev_high = df.iloc[i-5:i-1]['high'].max()
                if df.iloc[i]['high'] > prev_high and df.iloc[i]['close'] < prev_high:
                    df.loc[i, 'pattern'] = 'Liquidity Sweep (Upper)'
        
        return df
EOF

cat > charting.py << 'EOF'
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import pandas as pd

def create_candlestick_chart(df, title="Price Chart"):
    fig = make_subplots(
        rows=2, cols=1,
        shared_xaxes=True,
        vertical_spacing=0.1,
        row_heights=[0.7, 0.3]
    )
    
    fig.add_trace(
        go.Candlestick(
            x=df['time'],
            open=df['open'],
            high=df['high'],
            low=df['low'],
            close=df['close'],
            name='OHLC',
            row=1, col=1
        )
    )
    
    colors = ['red' if row['close'] < row['open'] else 'green' 
              for _, row in df.iterrows()]
    
    fig.add_trace(
        go.Bar(
            x=df['time'],
            y=df['volume'],
            name='Volume',
            marker_color=colors,
            row=2, col=1,
            showlegend=False
        )
    )
    
    for idx, row in df.iterrows():
        if pd.notna(row.get('pattern')):
            fig.add_annotation(
                x=row['time'],
                y=row['high'],
                text=row['pattern'],
                showarrow=True,
                arrowhead=2,
                arrowsize=1,
                arrowwidth=2,
                arrowcolor="red",
                ax=0,
                ay=-40,
                font=dict(size=10, color="red")
            )
        
        if row.get('bos'):
            fig.add_vline(
                x=row['time'],
                line_dash="dash",
                line_color="red",
                row=1, col=1
            )
    
    fig.update_layout(
        title=f"{title} - Pattern Analysis",
        yaxis_title="Price",
        xaxis_title="Time",
        template="plotly_dark",
        hovermode='x unified',
        height=600,
        showlegend=True
    )
    
    return fig
EOF

cat > risk_calculator.py << 'EOF'
class RiskCalculator:
    def calculate_setup(self, entry, stop_loss, account_size, risk_percent):
        risk_amount = account_size * (risk_percent / 100)
        stop_distance = abs(entry - stop_loss)
        position_size = risk_amount / stop_distance
        
        tp_1_2 = entry + (stop_distance * 2)
        tp_1_3 = entry + (stop_distance * 3)
        tp_1_5 = entry + (stop_distance * 5)
        
        if entry > stop_loss:
            tp_1_2 = entry - (stop_distance * 2)
            tp_1_3 = entry - (stop_distance * 3)
            tp_1_5 = entry - (stop_distance * 5)
        
        return {
            'entry': entry,
            'stop_loss': stop_loss,
            'risk_amount': risk_amount,
            'stop_distance': stop_distance,
            'position_size': position_size,
            'tp_1_2': tp_1_2,
            'tp_1_3': tp_1_3,
            'tp_1_5': tp_1_5,
            'account_size': account_size,
            'risk_percent': risk_percent
        }
    
    def calculate_risk_reward_ratio(self, entry, stop, target):
        risk = abs(entry - stop)
        reward = abs(target - entry)
        return reward / risk if risk > 0 else 0
EOF

cat > alerts.py << 'EOF'
import requests
from datetime import datetime

class AlertManager:
    def __init__(self, discord_webhook=None, email=None, slack_webhook=None):
        self.discord_webhook = discord_webhook
        self.email = email
        self.slack_webhook = slack_webhook
        self.alerts_history = []
    
    def send_discord_alert(self, message, symbol, price, pattern):
        if not self.discord_webhook:
            return False
        
        embed = {
            "title": f"🚨 {pattern} Alert - {symbol}",
            "description": message,
            "fields": [
                {"name": "Symbol", "value": symbol},
                {"name": "Price", "value": f"${price:.2f}"},
                {"name": "Pattern", "value": pattern},
                {"name": "Time", "value": str(datetime.now())}
            ],
            "color": 16711680
        }
        
        data = {"embeds": [embed]}
        
        try:
            response = requests.post(self.discord_webhook, json=data)
            self.alerts_history.append({
                'type': 'Discord',
                'message': message,
                'timestamp': datetime.now()
            })
            return response.status_code == 204
        except Exception as e:
            print(f"Discord alert error: {e}")
            return False
    
    def send_slack_alert(self, message, symbol, price):
        if not self.slack_webhook:
            return False
        
        payload = {
            "text": f"📊 *{symbol}* Alert",
            "blocks": [
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": f"*{symbol}* - ${price:.2f}\n{message}"
                    }
                }
            ]
        }
        
        try:
            response = requests.post(self.slack_webhook, json=payload)
            self.alerts_history.append({
                'type': 'Slack',
                'message': message,
                'timestamp': datetime.now()
            })
            return response.status_code == 200
        except Exception as e:
            print(f"Slack alert error: {e}")
            return False
EOF

cat > trade_journal.py << 'EOF'
import pandas as pd
import sqlite3
from datetime import datetime

class TradeJournal:
    def __init__(self, db_path='trades.db'):
        self.db_path = db_path
        self._init_db()
    
    def _init_db(self):
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS trades (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                symbol TEXT NOT NULL,
                entry_price REAL NOT NULL,
                exit_price REAL NOT NULL,
                entry_time TIMESTAMP,
                exit_time TIMESTAMP,
                pnl REAL,
                pnl_percent REAL,
                pattern TEXT,
                status TEXT,
                notes TEXT
            )
        ''')
        
        conn.commit()
        conn.close()
    
    def add_trade(self, trade_data):
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            INSERT INTO trades 
            (symbol, entry_price, exit_price, entry_time, exit_time, pnl, pnl_percent, pattern, status, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            trade_data.get('symbol'),
            trade_data.get('entry'),
            trade_data.get('exit'),
            trade_data.get('entry_time', datetime.now()),
            trade_data.get('exit_time'),
            trade_data.get('pnl'),
            trade_data.get('pnl_percent'),
            trade_data.get('pattern'),
            trade_data.get('status', 'closed'),
            trade_data.get('notes')
        ))
        
        conn.commit()
        conn.close()
    
    def get_recent_trades(self, limit=10):
        conn = sqlite3.connect(self.db_path)
        df = pd.read_sql_query(
            f'SELECT * FROM trades ORDER BY id DESC LIMIT {limit}',
            conn
        )
        conn.close()
        return df
    
    def export_trades(self, filename='trades_export.csv'):
        conn = sqlite3.connect(self.db_path)
        df = pd.read_sql_query('SELECT * FROM trades', conn)
        conn.close()
        
        df.to_csv(filename, index=False)
        return filename
EOF

cat > backtesting.py << 'EOF'
import pandas as pd
import numpy as np

class Backtester:
    def __init__(self, initial_capital=10000):
        self.initial_capital = initial_capital
        self.trades = []
        self.equity_curve = [initial_capital]
    
    def run_backtest(self, df, strategy_func):
        capital = self.initial_capital
        position = None
        
        for i in range(len(df)):
            signal = strategy_func(df, i)
            current_price = df.iloc[i]['close']
            
            if signal == 'BUY' and position is None:
                position = {
                    'type': 'long',
                    'entry_price': current_price,
                    'entry_index': i,
                    'size': capital / current_price
                }
            
            elif signal == 'SELL' and position is not None:
                pnl = (current_price - position['entry_price']) * position['size']
                pnl_percent = (pnl / capital) * 100
                
                self.trades.append({
                    'entry_price': position['entry_price'],
                    'exit_price': current_price,
                    'entry_index': position['entry_index'],
                    'exit_index': i,
                    'pnl': pnl,
                    'pnl_percent': pnl_percent,
                    'type': 'long'
                })
                
                capital += pnl
                self.equity_curve.append(capital)
                position = None
        
        return self.calculate_metrics()
    
    def calculate_metrics(self):
        df_trades = pd.DataFrame(self.trades)
        
        if len(df_trades) == 0:
            return None
        
        total_trades = len(df_trades)
        winning_trades = len(df_trades[df_trades['pnl'] > 0])
        losing_trades = len(df_trades[df_trades['pnl'] < 0])
        win_rate = (winning_trades / total_trades * 100) if total_trades > 0 else 0
        
        avg_win = df_trades[df_trades['pnl'] > 0]['pnl'].mean() if winning_trades > 0 else 0
        avg_loss = df_trades[df_trades['pnl'] < 0]['pnl'].mean() if losing_trades > 0 else 0
        
        total_return = ((self.equity_curve[-1] - self.initial_capital) / self.initial_capital) * 100
        max_drawdown = self._calculate_max_drawdown()
        
        return {
            'total_trades': total_trades,
            'winning_trades': winning_trades,
            'losing_trades': losing_trades,
            'win_rate': win_rate,
            'avg_win': avg_win,
            'avg_loss': avg_loss,
            'total_return': total_return,
            'max_drawdown': max_drawdown,
            'profit_factor': abs(avg_win / avg_loss) if avg_loss != 0 else 0
        }
    
    def _calculate_max_drawdown(self):
        equity = np.array(self.equity_curve)
        running_max = np.maximum.accumulate(equity)
        drawdown = (equity - running_max) / running_max
        return np.min(drawdown) * 100
EOF

cat > requirements.txt << 'EOF'
streamlit==1.28.1
pandas==2.0.3
numpy==1.24.3
plotly==5.17.0
ccxt==4.0.56
python-dotenv==1.0.0
requests==2.31.0
websockets==11.0.3
EOF

cat > .env.example << 'EOF'
COINBASE_API_KEY=your_api_key_here
COINBASE_API_SECRET=your_secret_here
COINBASE_PASSPHRASE=your_passphrase_here
EMAIL_ADDRESS=your_email@gmail.com
EMAIL_PASSWORD=your_app_password
DISCORD_WEBHOOK=https://discord.com/api/webhooks/your_webhook_here
SLACK_WEBHOOK=https://hooks.slack.com/services/your_webhook_here
EOF

cat > .gitignore << 'EOF'
.env
__pycache__/
*.py[cod]
*$py.class
*.so
.DS_Store
.venv
venv/
*.db
*.log
.streamlit/secrets.toml
EOF

cat > Dockerfile << 'EOF'
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8501

CMD ["streamlit", "run", "main.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  dashboard:
    build: .
    ports:
      - "8501:8501"
    environment:
      - COINBASE_API_KEY=${COINBASE_API_KEY}
      - COINBASE_API_SECRET=${COINBASE_API_SECRET}
      - COINBASE_PASSPHRASE=${COINBASE_PASSPHRASE}
      - DISCORD_WEBHOOK=${DISCORD_WEBHOOK}
      - SLACK_WEBHOOK=${SLACK_WEBHOOK}
    volumes:
      - ./trades.db:/app/trades.db
    networks:
      - trading_network

networks:
  trading_network:
    driver: bridge
EOF

echo "✅ All files created successfully!"
